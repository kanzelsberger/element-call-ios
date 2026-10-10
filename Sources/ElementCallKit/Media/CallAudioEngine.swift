//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Synchronization

/// One `AVAudioEngine` for both directions: the platform's echo cancellation only works when the
/// microphone and the speaker live in the same IO unit.
///
/// Under CallKit the engine must only start once the provider activated the audio session
/// (`didActivate`), never before — starting early yields silence or `-10868`.
@available(iOS 18, *)
final nonisolated class CallAudioEngine: @unchecked Sendable {
    /// Every `AVAudioEngine` mutation happens here, in order, and nothing else does.
    ///
    /// This used to be an `NSLock`, and the difference matters. The engine takes its own recursive
    /// mutex and then the render graph's, so any thread holding a lock across an engine call while
    /// the render thread wants the same lock closes a cycle. A serial queue gives the same mutual
    /// exclusion over the state below with nothing the real-time thread can ever block on, and it
    /// keeps graph reconfiguration off the main thread at hang-up.
    ///
    /// **Never `sync` onto this queue, and never from inside it.**
    /// `AVAudioEngineConfigurationChange` is posted *synchronously* by `attach` and `connect`, so
    /// this queue can be mid-attach at the moment a restart is enqueued.
    private let queue = DispatchQueue(label: "io.element.elementcall.audio-engine", qos: .userInitiated)
    
    private let engine = AVAudioEngine()
    
    /// The hardware input format, published as a value for the render path to read.
    ///
    /// Asking the engine for this is a mutex acquisition, and the microphone sink block used to do
    /// exactly that on the real-time thread — which deadlocked hang-up against `detach`. Readers
    /// take the snapshot; only this class asks the engine.
    let inputFormat = InputFormatSnapshot()
    
    // Everything below is confined to `queue`.
    private var isVoiceProcessingConfigured = false
    private var inputReceiver: InputSinkReceiver?
    private var sinkNode: AVAudioSinkNode?
    private var renderBlocks = [String: SourceRenderBlock]()
    private var sourceNodes = [String: AVAudioSourceNode]()
    private var isRunning = false
    private var configurationObserver: NSObjectProtocol?
    
    /// Boxed rather than stored bare for the reason given in AGENTS.md: a function value copied in
    /// and out of storage reabstracts on every copy, and these are re-read on every restart.
    ///
    /// `@unchecked` because AVFAudio's block typealiases are not `@Sendable`, and the attribute
    /// cannot be applied to a typealias, so there is no way to state what is actually true here:
    /// the only thing either box ever carries is `MicrophoneTap.receiverBlock` or
    /// `AudioPlaybackRenderer.renderBlock`, and each of those captures exactly one object, itself
    /// `@unchecked Sendable` and hand-synchronised for the render thread. Re-declaring Apple's
    /// signatures with `@Sendable` would make it checked, at the cost of duplicating them in six
    /// places that would silently drift. Keep one stored property each, or that reasoning lapses.
    private struct InputSinkReceiver: @unchecked Sendable {
        let block: AVAudioSinkNodeReceiverBlock
    }
    
    private struct SourceRenderBlock: @unchecked Sendable {
        let block: AVAudioSourceNodeRenderBlock
    }
    
    init() {
        // Posted synchronously on whichever thread reconfigured the graph — which may be `queue`
        // itself, mid-attach — so the restart must be enqueued rather than run here.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                       object: engine,
                                                                       queue: nil) { [weak self] _ in
            MatrixRTCLog.info("Audio engine configuration changed, restarting")
            self?.restart()
        }
    }
    
    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        // Safe to touch the engine off the queue only because every block enqueued below upgrades a
        // weak self: none can be running while this is, and none still queued will do anything. If
        // a future change captures self strongly in one of them, deinit becomes unreachable and
        // this stops being true. A running engine that outlives the owner of its render blocks
        // renders from freed memory.
        engine.stop()
    }
    
    /// Installs the microphone sink. `receiver` runs on the real-time thread: copy and return.
    func installInputSink(_ receiver: @escaping AVAudioSinkNodeReceiverBlock) {
        let boxed = InputSinkReceiver(block: receiver)
        queue.async { [weak self] in
            guard let self else { return }
            inputReceiver = boxed
            attachInputSink()
        }
    }
    
    /// Detaching the sink was missing entirely: `MicrophoneCapturer.stop()` cancelled its drainer
    /// and left the node firing into a ring nobody read for the rest of the process's life, which
    /// is why the render thread was still contending for the engine's mutex during teardown.
    func removeInputSink() {
        queue.async { [weak self] in
            guard let self else { return }
            inputReceiver = nil
            if let sinkNode {
                engine.detach(sinkNode)
                self.sinkNode = nil
            }
        }
    }
    
    func addSourceNode(for memberID: String, render: @escaping AVAudioSourceNodeRenderBlock) {
        let boxed = SourceRenderBlock(block: render)
        queue.async { [weak self] in
            guard let self else { return }
            renderBlocks[memberID] = boxed
            attachSourceNode(for: memberID)
        }
    }
    
    func removeSourceNode(for memberID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            renderBlocks[memberID] = nil
            guard let node = sourceNodes.removeValue(forKey: memberID) else { return }
            // `detach` disconnects. The explicit `disconnectNodeInput` that used to sit here was a
            // no-op anyway: a source node has no input bus.
            engine.detach(node)
        }
    }
    
    /// Call from CallKit's `didActivate` (or directly on the simulator, where CallKit never activates).
    func start() {
        queue.async { [weak self] in self?.startNow() }
    }
    
    /// Call from CallKit's `didDeactivate`; the session itself is CallKit's to deactivate.
    func stop() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            engine.stop()
            isRunning = false
            MatrixRTCLog.info("Audio engine stopped")
        }
    }
    
    /// Tears the whole graph down in one hop, for hang-up.
    ///
    /// Detaching ten remote members one call at a time is ten graph reconfigurations, each able to
    /// post its own configuration-change notification while the previous one is still settling.
    func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            if isRunning {
                engine.stop()
                isRunning = false
            }
            if let sinkNode {
                engine.detach(sinkNode)
                self.sinkNode = nil
            }
            for node in sourceNodes.values {
                engine.detach(node)
            }
            sourceNodes.removeAll()
            renderBlocks.removeAll()
            inputReceiver = nil
            MatrixRTCLog.info("Audio engine shut down")
        }
    }
    
    // MARK: - Private
    
    /// What the input node currently reports, as a value. Only meaningful off the render thread.
    private var hardwareInputFormat: InputStreamFormat {
        dispatchPrecondition(condition: .onQueue(queue))
        return InputStreamFormat(engine.inputNode.outputFormat(forBus: 0))
    }
    
    private func startNow() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isRunning else { return }
        // Checked before *any* graph mutation, not just the input connect: the mixer-to-output
        // connect below is the same unprotected Objective-C call and fails the same way. Bailing
        // whole is also the honest answer -- with no session there is nothing to play out of
        // either. `isRunning` stays false, so the next startAudioIfReady retries.
        let hardware = hardwareInputFormat
        guard hardware.isUsable else {
            MatrixRTCLog.warning("Audio session is not active (input format \(hardware)); not starting the engine")
            return
        }
        if !isVoiceProcessingConfigured {
            // Voice processing (AEC/AGC/NS) must be enabled before prepare(), and only once the
            // session is active or the input format reads as 0 Hz.
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
            } catch {
                // The simulator has no voice processing; a call without AEC still works.
                MatrixRTCLog.warning("Voice processing unavailable: \(error)")
            }
            isVoiceProcessingConfigured = true
        }
        // Keep the output path alive even with no remote member yet, so the mixer format is fixed.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        
        // Rebuilt from the stored blocks on every start, not just the first. A configuration change
        // leaves the nodes attached but their connections gone and hands the input node a new
        // format, so a restart that only called `engine.start()` would come back deaf. This is what
        // the old `onConfigurationChange` hook was for — nothing ever assigned it, so the reinstall
        // simply never happened. Doing it here leaves no window in which the graph is up but the
        // sink is not.
        attachInputSink()
        for memberID in renderBlocks.keys {
            attachSourceNode(for: memberID)
        }
        
        engine.prepare()
        do {
            try engine.start()
        } catch {
            MatrixRTCLog.error("Failed starting the audio engine: \(error)")
            return
        }
        isRunning = true
        // The hardware format is only real once the engine is running, and a restart after a route
        // change lands here with a different one.
        let format = engine.inputNode.outputFormat(forBus: 0)
        inputFormat.store(InputStreamFormat(format))
        MatrixRTCLog.info("Audio engine started, input \(format)")
    }
    
    private func restart() {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            engine.stop()
            isRunning = false
            // One hop, so two notifications in quick succession cannot interleave a stop with a
            // start and leave the engine down.
            startNow()
        }
    }
    
    private func attachInputSink() {
        dispatchPrecondition(condition: .onQueue(queue))
        if let sinkNode {
            engine.detach(sinkNode)
            self.sinkNode = nil
        }
        guard let inputReceiver else { return }
        // installInputSink can land before the session is active -- always on an iOS app running
        // on macOS, where CallKit never activates it, and racily on iOS if the microphone is
        // published first. The receiver stays stored, so `startNow` attaches it once the format
        // is real; connecting against an unusable one would kill the process instead.
        let hardware = hardwareInputFormat
        guard hardware.isUsable else {
            MatrixRTCLog.warning("Input format \(hardware) is unusable; deferring the microphone sink")
            return
        }
        // Published before the node goes live: the block reads the format on its very first
        // callback, and the engine may already be running.
        inputFormat.store(hardware)
        let node = AVAudioSinkNode(receiverBlock: inputReceiver.block)
        engine.attach(node)
        // The sink takes the input node's own format; converting happens off the render thread.
        engine.connect(engine.inputNode, to: node, format: nil)
        sinkNode = node
    }
    
    private func attachSourceNode(for memberID: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let existing = sourceNodes.removeValue(forKey: memberID) {
            engine.detach(existing)
        }
        guard let render = renderBlocks[memberID] else { return }
        let node = AVAudioSourceNode(format: AudioFormat.float32, renderBlock: render.block)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: AudioFormat.float32)
        sourceNodes[memberID] = node
    }
}
