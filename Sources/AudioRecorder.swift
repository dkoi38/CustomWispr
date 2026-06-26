import AVFoundation
import Foundation

/// Records microphone audio for push-to-talk dictation.
///
/// Design notes — this fixes word-clipping at the start and end of dictation:
///   • The AVAudioEngine is started on first use and kept warm between dictations, so the
///     microphone is already live when you press the hotkey. Previously a brand-new
///     engine was cold-started on every keypress, and the ~100-300ms it took the mic
///     to spin up swallowed the first word(s).
///   • A small rolling "pre-roll" ring buffer continuously holds the last ~300ms of
///     audio. When recording starts, that pre-roll is written first, so a word spoken
///     in the instant before/at the keypress is still captured.
///   • On stop, capture continues for a short "hangover" (~250ms) before the file is
///     closed, so the tail of your last word isn't clipped.
///
/// The engine stays warm between dictations, then releases the mic after a short idle
/// window (`idleReleaseSeconds`) so the macOS mic indicator goes dark when you're not
/// dictating. Successive dictations within the window stay warm (no clipping); only the
/// first dictation after an idle gap pays the cold-start cost.
class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?

    /// Token for the audio-configuration-change observer. Lets us rebuild the warm engine
    /// when the input device or format changes out from under us.
    private var configObserver: NSObjectProtocol?
    private var rebuildRetries = 0

    /// Release the warm mic — and clear the macOS mic indicator — after this many seconds
    /// with no dictation. Successive dictations within the window stay warm (no clipping).
    private let idleReleaseSeconds: TimeInterval = 60
    private var idleReleaseWorkItem: DispatchWorkItem?

    /// whisper.cpp wants 16kHz mono float32 natively.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Pre-roll: keep the last 300ms (16kHz * 0.3s = 4800 samples) so the opening
    /// word spoken right as the hotkey is pressed isn't lost.
    private let preRollSamples = 4800
    private var ring = [Float]()

    /// Hangover so the final word's tail isn't clipped.
    private let hangoverSeconds: TimeInterval = 0.25

    /// Guards `ring`, `isCapturing`, and `audioFile`. Held briefly on the audio thread.
    private let stateLock = NSLock()
    private var isCapturing = false
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    init() {
        // Recover automatically when the audio hardware configuration changes — e.g. a
        // meeting app (Zoom/Fathom) grabs the mic, AirPods flip into headset mode, or the
        // default input device changes. AVAudioEngine does NOT follow such changes on its
        // own: the running input tap goes permanently silent, so every dictation captures
        // only the 0.3s pre-roll of silence and Whisper hallucinates "thank you." We
        // rebuild the warm engine so it re-binds to the new device. Delivered on the main
        // queue to stay ordered with startRecording()/teardown().
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildEngine()
        }
    }

    deinit {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Rebuild the warm engine against the CURRENT default input device. Runs on the main
    /// queue after an audio-configuration change. A freshly-switched device can briefly
    /// report an invalid (0 Hz) format, so prewarm() may fail transiently — retry without
    /// blocking the main thread until it succeeds (or we give up after a few seconds).
    private func rebuildEngine() {
        // Only recover an engine that is meant to be live. If the mic was released while
        // idle, stay released — the next dictation prewarms fresh against the current
        // device — so a device change doesn't relight the mic indicator while idle.
        stateLock.lock()
        let capturing = isCapturing
        stateLock.unlock()
        guard audioEngine != nil || capturing else { return }

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        converter = nil

        if prewarm() {
            rebuildRetries = 0
            NSLog("CustomWispr: audio engine rebuilt after device change")
        } else if rebuildRetries < 15 {
            rebuildRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.rebuildEngine()
            }
        } else {
            rebuildRetries = 0
            NSLog("CustomWispr: failed to rebuild audio engine after device change")
        }
    }

    /// Start the engine and keep it warm. Safe to call repeatedly (no-op once running).
    @discardableResult
    func prewarm() -> Bool {
        if audioEngine != nil { return true }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0 else { return false }
        guard let conv = AVAudioConverter(from: hardwareFormat, to: targetFormat) else { return false }
        self.converter = conv

        let sampleRateRatio = 16000.0 / hardwareFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            let outputCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * sampleRateRatio))
            guard outputCapacity > 0,
                  let converted = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: outputCapacity) else { return }

            var provided = false
            var error: NSError?
            conv.convert(to: converted, error: &error) { _, outStatus in
                if provided { outStatus.pointee = .noDataNow; return nil }
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, converted.frameLength > 0 else { return }

            self.handleConverted(converted)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.converter = nil
            return false
        }

        self.audioEngine = engine
        return true
    }

    /// Audio-thread callback for every converted 16kHz mono buffer.
    private func handleConverted(_ converted: AVAudioPCMBuffer) {
        guard let ch = converted.floatChannelData?[0] else { return }
        let n = Int(converted.frameLength)

        stateLock.lock()
        // Keep the rolling pre-roll up to date at all times.
        ring.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        if ring.count > preRollSamples {
            ring.removeFirst(ring.count - preRollSamples)
        }
        // Write live audio while recording. Done under the lock so the file can't be
        // closed out from under us by stopRecording (avoids a use-after-free).
        if isCapturing, let file = audioFile {
            try? file.write(from: converted)
        }
        stateLock.unlock()
    }

    /// Begin a recording. Returns the temp WAV URL that will receive audio.
    func startRecording() throws -> URL {
        // Make sure the mic is warm (no-op if already running).
        guard prewarm() else { throw RecorderError.noMicrophone }

        // New dictation in progress — keep the mic warm; cancel any pending idle release.
        idleReleaseWorkItem?.cancel()
        idleReleaseWorkItem = nil

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("custom-wispr_\(UUID().uuidString).wav")

        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        // Snapshot the pre-roll and write it first, before the file is published to the
        // audio thread — so the opening word survives. No concurrent writers here.
        stateLock.lock()
        let preroll = ring
        stateLock.unlock()
        if let prerollBuffer = makeBuffer(from: preroll) {
            try? file.write(from: prerollBuffer)
        }

        stateLock.lock()
        tempFileURL = fileURL
        audioFile = file
        isCapturing = true
        stateLock.unlock()

        return fileURL
    }

    /// Stop recording after a short hangover so the last word's tail survives.
    /// `completion` is called on the main queue with the finished WAV URL.
    func stopRecording(completion: @escaping (URL?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + hangoverSeconds) { [weak self] in
            guard let self = self else { completion(nil); return }
            self.stateLock.lock()
            self.isCapturing = false
            self.audioFile = nil          // closes + flushes the WAV
            let url = self.tempFileURL
            self.stateLock.unlock()
            completion(url)

            // Let the mic go cold (indicator off) if no new dictation starts soon.
            self.scheduleIdleRelease()
        }
    }

    /// Release the warm engine once the idle window passes with no new recording, turning
    /// the microphone — and its menu-bar indicator — off until the next dictation.
    private func scheduleIdleRelease() {
        idleReleaseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let capturing = self.isCapturing
            self.stateLock.unlock()
            guard !capturing else { return }   // a new dictation started — stay warm
            self.teardown()                     // release mic → indicator goes dark
        }
        idleReleaseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleReleaseSeconds, execute: work)
    }

    private func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { src in
            ch.update(from: src.baseAddress!, count: samples.count)
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        return buf
    }

    func cleanup() {
        stateLock.lock()
        let url = tempFileURL
        tempFileURL = nil
        stateLock.unlock()
        if let url = url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Stop the warm engine (call on quit or after the idle window).
    func teardown() {
        idleReleaseWorkItem?.cancel()
        idleReleaseWorkItem = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
    }

    /// Remove stale temp files from previous sessions.
    static func cleanupStaleFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.lastPathComponent.hasPrefix("custom-wispr_") &&
            (file.pathExtension == "wav" || file.pathExtension == "m4a") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    enum RecorderError: LocalizedError {
        case noMicrophone

        var errorDescription: String? {
            switch self {
            case .noMicrophone:
                return "No microphone available or sample rate is 0."
            }
        }
    }
}
