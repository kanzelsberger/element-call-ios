//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@preconcurrency import AVFoundation
import CoreMedia
import MatrixRtc
import Synchronization
import UIKit

/// The local camera, published straight from the capture queue (`captureVideo` is synchronous).
///
/// Turning the camera off releases the device — the indicator going out is the point — while the
/// track stays published and muted at the transport, so peers see a deliberate camera-off rather
/// than a track disappearing.
@available(iOS 18, *)
final nonisolated class CameraCapturer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let captureWidth: UInt32 = 640
    static let captureHeight: UInt32 = 480
    
    private let queue = DispatchQueue(label: "io.element.matrixrtc.camera", qos: .userInitiated)
    private let state = Mutex<State>(.init())
    private let onLocalFrame: @Sendable (MatrixRTCVideoFrame) -> Void
    /// The system took the camera away (app in the background, another app using it) or gave it back.
    /// Without the multitasking-camera entitlement this fires on every backgrounding.
    var onInterruption: (@Sendable (Bool) -> Void)?
    private var interruptionObservers: [NSObjectProtocol] = []
    
    private struct State {
        var session: AVCaptureSession?
        var track: FfiLocalTrack?
        var isFrontFacing = true
        var rotation: FfiVideoRotation = .deg0
    }
    
    /// - Parameter onLocalFrame: a copy of each published frame for the self view.
    init(onLocalFrame: @escaping @Sendable (MatrixRTCVideoFrame) -> Void) {
        self.onLocalFrame = onLocalFrame
        super.init()
        let center = NotificationCenter.default
        interruptionObservers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: nil) { [weak self] notification in
                guard let self, notification.object as? AVCaptureSession === state.withLock({ $0.session }) else { return }
                let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap(AVCaptureSession.InterruptionReason.init)
                MatrixRTCLog.info("Camera interrupted: \(reason.map { "\($0)" } ?? "unknown reason")")
                onInterruption?(true)
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: nil) { [weak self] notification in
                guard let self, notification.object as? AVCaptureSession === state.withLock({ $0.session }) else { return }
                MatrixRTCLog.info("Camera interruption ended")
                onInterruption?(false)
            }
        ]
    }
    
    deinit {
        interruptionObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    
    var isFrontFacing: Bool {
        state.withLock { $0.isFrontFacing }
    }
    
    func start(track: FfiLocalTrack) throws {
        state.withLock { $0.track = track }
        let front = isFrontFacing
        try configureSession(front: front)
    }
    
    /// Stops on the capture queue (never blocking the caller); the session is kept alive by the
    /// closure until it has really stopped, which is what makes dropping it safe.
    func stop() {
        let session = state.withLock { state -> AVCaptureSession? in
            defer {
                state.session = nil
                state.track = nil
            }
            return state.session
        }
        guard let session else { return }
        queue.async {
            session.stopRunning()
            MatrixRTCLog.info("Camera released")
        }
    }
    
    /// Asynchronous by nature: one camera closes and another opens.
    func switchCamera() throws -> Bool {
        let front = !isFrontFacing
        try configureSession(front: front)
        return isFrontFacing
    }
    
    /// Called by the owner when the interface orientation changes; frames carry it, pixels are not rotated.
    func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        // Same table as libwebrtc's RTCCameraVideoCapturer, expressed in interface orientation
        // (interface landscapeLeft is the device turned to landscapeRight).
        let rotation: FfiVideoRotation = switch orientation {
        case .portrait: .deg90
        case .portraitUpsideDown: .deg270
        case .landscapeLeft: isFrontFacing ? .deg0 : .deg180
        case .landscapeRight: isFrontFacing ? .deg180 : .deg0
        default: .deg90
        }
        state.withLock { $0.rotation = rotation }
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let planes = I420Repacker.repack(pixelBuffer) else { return }
        let (track, rotation) = state.withLock { ($0.track, $0.rotation) }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampUs = Int64(CMTimeGetSeconds(timestamp) * 1_000_000)
        
        let frame = planes.ffiFrame(rotation: rotation, timestampUs: timestampUs)
        onLocalFrame(MatrixRTCVideoFrame(planes: planes, rotation: .init(rotation), isMirrored: isFrontFacing))
        
        guard let track else { return }
        do {
            try track.captureVideo(frame: frame)
        } catch {
            MatrixRTCLog.warning("captureVideo failed: \(error)")
        }
    }
    
    // MARK: - Private
    
    private func configureSession(front: Bool) throws {
        let position: AVCaptureDevice.Position = front ? .front : .back
        // Prefer the requested camera, fall back to whatever exists rather than refusing.
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first(where: { $0.position == position }) ?? discovery.devices.first else {
            throw MatrixRTCError.media("No camera available")
        }
        let input = try AVCaptureDeviceInput(device: device)
        
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MatrixRTCError.media("Cannot configure the camera session")
        }
        session.addInput(input)
        session.addOutput(output)
        // Deliver sensor-native frames; the rotation travels with the frame instead.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
        session.commitConfiguration()
        
        let previous = state.withLock { state -> AVCaptureSession? in
            defer {
                state.session = session
                state.isFrontFacing = device.position == .front
            }
            return state.session
        }
        // startRunning blocks; never on the main thread.
        queue.async {
            previous?.stopRunning()
            session.startRunning()
            MatrixRTCLog.info("Camera started (\(device.position == .front ? "front" : "back"))")
        }
    }
}
