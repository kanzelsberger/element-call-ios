//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import MetalKit
import SwiftUI

/// Draws a `VideoFrameSlot` with Metal and reports the drawn pixel size so the SFU can be asked
/// for a layer that fits.
@available(iOS 18, *)
public struct VideoTileView: UIViewRepresentable {
    let slot: VideoFrameSlot
    let presentation: VideoPresentation
    let onPixelSizeChange: (CGSize) -> Void
    /// The picture's own upright size, once a frame has been drawn. Only the renderer sees it, and
    /// a caller that fits rather than fills needs it to clamp a pan to the picture's edges.
    let onContentSizeChange: (CGSize) -> Void
    
    public init(slot: VideoFrameSlot,
                presentation: VideoPresentation = .fill,
                onPixelSizeChange: @escaping (CGSize) -> Void = { _ in },
                onContentSizeChange: @escaping (CGSize) -> Void = { _ in }) {
        self.slot = slot
        self.presentation = presentation
        self.onPixelSizeChange = onPixelSizeChange
        self.onContentSizeChange = onContentSizeChange
    }
    
    public func makeUIView(context: Context) -> VideoTileUIView {
        let view = VideoTileUIView(slot: slot)
        view.onPixelSizeChange = onPixelSizeChange
        view.onContentSizeChange = onContentSizeChange
        view.presentation = presentation
        return view
    }
    
    public func updateUIView(_ uiView: VideoTileUIView, context: Context) {
        uiView.onPixelSizeChange = onPixelSizeChange
        uiView.onContentSizeChange = onContentSizeChange
        uiView.presentation = presentation
    }
    
    public static func dismantleUIView(_ uiView: VideoTileUIView, coordinator: ()) {
        uiView.release()
    }
}

@available(iOS 18, *)
public final class VideoTileUIView: UIView {
    var onPixelSizeChange: ((CGSize) -> Void)?
    var onContentSizeChange: ((CGSize) -> Void)?
    
    var presentation: VideoPresentation = .fill {
        didSet {
            guard presentation != oldValue else { return }
            renderer?.setPresentation(presentation)
            // Nothing else asks for a draw between frames, and a paused or stalled stream still has
            // to follow the fingers: the last frame is retained precisely so it can be redrawn.
            requestDraw()
            reportDrawnSize()
        }
    }
    
    private let metalView = MTKView()
    private var renderer: I420MetalRenderer?
    private var lastReportedSize: CGSize = .zero
    /// The picture's upright size in its own pixels, zero until a frame has been drawn.
    private var contentPixelSize: CGSize = .zero
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// GPU work is forbidden while the app is not active: `nextDrawable` blocks and the system kills
    /// the process. Locking the phone mid-call is the common way to get there.
    private var isRenderingAllowed = UIApplication.shared.applicationState == .active
    
    init(slot: VideoFrameSlot) {
        super.init(frame: .zero)
        // Built after `super.init` so the content-size callback can hold this view: the renderer
        // runs nonisolated and hops back, the way the sample-buffer view's does.
        renderer = I420MetalRenderer(slot: slot) { [weak self] size in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.contentSizeChanged(size) }
            }
        }
        backgroundColor = .black
        
        metalView.device = renderer.map { _ in I420MetalRenderer.device } ?? nil
        metalView.delegate = renderer
        metalView.framebufferOnly = true
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.backgroundColor = .black
        metalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        
        // A frame arriving requests one draw; MTKView coalesces requests to the display rate.
        slot.setOnFrame { [weak self] in
            DispatchQueue.main.async { self?.requestDraw() }
        }
        
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isRenderingAllowed = false }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isRenderingAllowed = true
                    self?.requestDraw()
                }
            }
        ]
    }
    
    private func contentSizeChanged(_ size: CGSize) {
        guard size != contentPixelSize else { return }
        contentPixelSize = size
        onContentSizeChange?(size)
        // Under fit this changes how much of the surface the picture covers, and so what is worth
        // asking the SFU for.
        reportDrawnSize()
    }
    
    private func requestDraw() {
        guard isRenderingAllowed else { return }
        metalView.setNeedsDisplay()
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func layoutSubviews() {
        super.layoutSubviews()
        // A resize is a redraw. `isPaused` means the only things that draw are a frame arriving and
        // a zoom, so a view whose bounds are being animated kept showing the picture it last drew,
        // stretched by the compositor to whatever shape it had reached: through a tile growing to
        // full screen the picture squashed and then snapped straight the instant the next frame
        // landed. Worse the further the aspect travels, and worse again once full screen started
        // fitting rather than filling, because then the letterbox itself depends on the shape.
        requestDraw()
        reportDrawnSize()
    }
    
    /// What the SFU should be asked for: the size the picture is actually drawn at, times the zoom.
    ///
    /// `layoutSubviews` alone is not enough, because a zoom changes neither the bounds nor the
    /// drawable; it is called from there, from a zoom, and from a change of content size.
    private func reportDrawnSize() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        var size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        // Only once it has arrived. Mid-blend the letterbox is still opening, and folding that into
        // the report would ask the SFU for a different size on every frame of the move for nothing.
        if presentation.fit > 0.999, contentPixelSize.width > 0, contentPixelSize.height > 0 {
            // Fit letterboxes, and nobody has to send us the bars.
            let factor = min(size.width / contentPixelSize.width, size.height / contentPixelSize.height)
            size = CGSize(width: contentPixelSize.width * factor, height: contentPixelSize.height * factor)
        }
        // Zoomed in, each source pixel covers more of the screen, so ask for that many more of them.
        // Quantised to the powers of two simulcast layers are spaced by: the 16 px snap downstream
        // absorbs layout jitter, but a continuous pinch would otherwise be a round trip every few
        // points, and most of them would land back on the layer we already had. Capped rather than
        // held to what is currently arriving, which would be a ratchet that could never go up.
        let zoom = min(Self.maximumZoomRequest, max(1, exp2(log2(max(1, presentation.zoom)).rounded())))
        size = CGSize(width: (size.width * zoom).rounded(), height: (size.height * zoom).rounded())
        guard size != lastReportedSize, size.width > 0 else { return }
        lastReportedSize = size
        onPixelSizeChange?(size)
    }
    
    private static let maximumZoomRequest: CGFloat = 4
    
    func release() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
        renderer?.slot.setOnFrame(nil)
        renderer?.release()
    }
}
