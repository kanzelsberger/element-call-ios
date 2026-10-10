//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Synchronization
import UIKit

/// Draws a `VideoFrameSlot` through `AVSampleBufferDisplayLayer`, which the media server composites,
/// so it keeps working where Metal may not: the Picture in Picture window while the app is in the
/// background. Rotation and mirroring are a layer transform; pixels are only repacked to NV12.
@available(iOS 18, *)
public final class SampleBufferVideoView: UIView {
    public var slot: VideoFrameSlot {
        renderer.slot
    }
    
    /// The upright aspect ratio (width / height) of what is being shown, reported on the main thread when it changes.
    public var onAspectChange: ((CGFloat) -> Void)?
    /// The drawn size in pixels, so the SFU can be asked for a layer that fits the window.
    public var onPixelSizeChange: ((CGSize) -> Void)?
    /// Whether any frame has reached the layer since the last ``clear()``.
    ///
    /// Picture in Picture needs this: `startPictureInPicture()` on a layer with no content fails
    /// with `AVKitErrorDomain -1001` rather than waiting.
    public private(set) var hasDrawnContent = false
    /// Fired on the main thread when the first frame reaches the layer, and again after a
    /// ``clear()``. Unlike ``onAspectChange`` it does not wait for the aspect to *change*, so it
    /// still fires for a stream whose shape matches the one before it.
    public var onFirstFrame: (() -> Void)?
    private var lastReportedSize: CGSize = .zero
    
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let renderer: SampleBufferRenderer
    private var orientation: (rotation: MatrixRTCVideoRotation, isMirrored: Bool) = (.deg0, false)
    private var lastAspect: CGFloat = 0
    
    override public init(frame: CGRect) {
        renderer = SampleBufferRenderer(layer: displayLayer)
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(displayLayer)
        
        renderer.onFrameShown = { [weak self] rotation, isMirrored, aspect in
            DispatchQueue.main.async {
                self?.frameShown(rotation: rotation, isMirrored: isMirrored, aspect: aspect)
            }
        }
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func layoutSubviews() {
        super.layoutSubviews()
        applyTransform()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if size != lastReportedSize, size.width > 0 {
            lastReportedSize = size
            onPixelSizeChange?(size)
        }
    }
    
    /// Drops what is on screen, e.g. when the member being shown changes.
    public func clear() {
        hasDrawnContent = false
        renderer.clear()
    }
    
    // MARK: - Private
    
    private func frameShown(rotation: MatrixRTCVideoRotation, isMirrored: Bool, aspect: CGFloat) {
        if !hasDrawnContent {
            hasDrawnContent = true
            onFirstFrame?()
        }
        if orientation != (rotation, isMirrored) {
            orientation = (rotation, isMirrored)
            applyTransform()
        }
        if abs(aspect - lastAspect) > 0.01 {
            lastAspect = aspect
            onAspectChange?(aspect)
        }
    }
    
    /// The layer keeps the view's bounds and is rotated in place. The frame's rotation is how far it must
    /// turn clockwise to be upright, which in UIKit's y-down space is a positive angle. Mirroring is applied
    /// after the rotation, in display space (before it, a 90° frame would flip vertically instead).
    private func applyTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.setAffineTransform(.identity)
        let rotated = orientation.rotation == .deg90 || orientation.rotation == .deg270
        displayLayer.bounds = rotated ? CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width) : bounds
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CGAffineTransform(rotationAngle: CGFloat(orientation.rotation.rawValue) * .pi / 180)
        if orientation.isMirrored {
            transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1))
        }
        displayLayer.setAffineTransform(transform)
        CATransaction.commit()
    }
}

/// The off-main half: packs frames and enqueues them. `AVSampleBufferDisplayLayer.enqueue` is safe
/// to call from any thread; everything else about the layer stays on the view.
@available(iOS 18, *)
private final nonisolated class SampleBufferRenderer: @unchecked Sendable {
    let slot = VideoFrameSlot()
    var onFrameShown: (@Sendable (MatrixRTCVideoRotation, Bool, CGFloat) -> Void)?
    
    private let layer: AVSampleBufferDisplayLayer
    private let packer = NV12Packer()
    private let queue = DispatchQueue(label: "io.element.matrixrtc.samplebuffer", qos: .userInteractive)
    
    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        slot.setOnFrame { [weak self] in
            self?.queue.async { self?.drainSlot() }
        }
    }
    
    func clear() {
        slot.clear()
        queue.async { [layer] in
            layer.flushAndRemoveImage()
        }
    }
    
    private func drainSlot() {
        guard let frame = slot.take() else { return }
        
        if layer.status == .failed {
            MatrixRTCLog.warning("Sample buffer layer failed: \(layer.error.map { "\($0)" } ?? "unknown"), flushing")
            layer.flush()
        }
        // Latest frame wins: a busy layer simply skips this one.
        guard layer.isReadyForMoreMediaData, let sampleBuffer = packer.makeSampleBuffer(from: frame) else { return }
        layer.enqueue(sampleBuffer)
        
        let rotated = frame.rotation == .deg90 || frame.rotation == .deg270
        let aspect = CGFloat(rotated ? frame.height : frame.width) / CGFloat(max(1, rotated ? frame.width : frame.height))
        onFrameShown?(frame.rotation, frame.isMirrored, aspect)
    }
}
