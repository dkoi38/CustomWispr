import AVFoundation
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var tempFileURL: URL?

    func startRecording() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("custom-wispr_\(UUID().uuidString).wav")
        self.tempFileURL = fileURL

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0 else {
            throw RecorderError.noMicrophone
        }

        // Downsample to 16kHz mono — whisper.cpp wants 16kHz natively, so this
        // avoids server-side resampling AND uploads stay tiny.
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let conv = AVAudioConverter(from: hardwareFormat, to: targetFormat)!
        self.converter = conv

        // Write 16kHz mono 16-bit PCM WAV on disk; AVAudioFile auto-converts
        // from the float32 in-memory buffers we hand it.
        let audioFile = try AVAudioFile(
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

        let sampleRateRatio = 16000.0 / hardwareFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
            let outputCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * sampleRateRatio))
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return }

            var provided = false
            var error: NSError?
            conv.convert(to: converted, error: &error) { _, outStatus in
                if provided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil && converted.frameLength > 0 {
                try? audioFile.write(from: converted)
            }
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.audioFile = audioFile

        return fileURL
    }

    func stopRecording() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        converter = nil
        return tempFileURL
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    /// Remove stale temp files from previous sessions
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
