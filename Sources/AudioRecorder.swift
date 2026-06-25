import AVFoundation
import Foundation

/// Records microphone audio for push-to-talk dictation.
///
/// Design notes — this fixes word-clipping at the start and end of dictation:
///   • The AVAudioEngine is started ONCE and kept warm for the app's lifetime, so the
///     microphone is already live when you press the hotkey. Previously a brand-new
///     engine was cold-started on every keypress, and the ~100-300ms it took the mic
///     to spin up swallowed the first word(s).
///   • A small rolling "pre-roll" ring buffer continuously holds the last ~300ms of
///     audio. When recording starts, that pre-roll is written first, so a word spoken
///     in the instant before/at the keypress is still captured.
///   • On stop, capture continues for a short "hangover" (~250ms) before the file is
///     closed, so the tail of your last word isn't clipped. The engine stays warm.
///
/// Trade-off: because the mic stays warm after first use, the macOS microphone
/// indicator stays on while the app runs. That is the cost of zero start-clipping.
class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?

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
        }
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

    /// Stop the warm engine (call on quit).
    func teardown() {
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
