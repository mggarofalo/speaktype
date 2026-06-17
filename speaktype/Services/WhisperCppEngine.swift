import AVFoundation
import Foundation
import OSLog
import WhisperCPP

/// whisper.cpp (Metal) transcription backend, used by the beta build to
/// benchmark against WhisperKit/CoreML. An actor so the blocking native
/// `whisper_full` call runs off the main thread and is serialized.
///
/// Observable UI state (isLoading/isTranscribing/...) is owned by WhisperService,
/// which delegates here when the `transcriptionEngine` default is `whispercpp`.
actor WhisperCppEngine {
    private var context: WhisperCPPContext?
    private(set) var loadedModelPath: String?

    var isLoaded: Bool { context != nil }

    func load(modelPath: String) throws {
        if loadedModelPath == modelPath, context != nil { return }
        let start = Date()
        context = try WhisperCPPContext(modelPath: modelPath, useGPU: true)
        loadedModelPath = modelPath
        let dt = Date().timeIntervalSince(start)
        AppLogger.transcription.info(
            "⏱️ whisper.cpp model loaded in \(String(format: "%.1f", dt), privacy: .public)s [compute=whispercpp]"
        )
    }

    func transcribe(audioFile: URL, language: String) throws -> String {
        guard let context else { throw WhisperService.TranscriptionError.notInitialized }

        let samples = try Self.decodePCM(url: audioFile)
        let lang = (language == "auto") ? nil : language
        let threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        // Vocabulary parity with the WhisperKit path: bias decoding toward the
        // user's custom glossary via whisper.cpp's initial_prompt.
        let initialPrompt = WhisperService.vocabularyPrompt(
            from: UserDefaults.standard.string(forKey: "customVocabulary") ?? "")

        let start = Date()
        let raw = try context.transcribe(
            samples: samples, language: lang, initialPrompt: initialPrompt, threads: threads)
        let infer = Date().timeIntervalSince(start)
        let audioSeconds = Double(samples.count) / 16000.0
        let rtf = audioSeconds > 0 ? infer / audioSeconds : 0
        AppLogger.transcription.info(
            "⏱️ Transcribed \(String(format: "%.1f", audioSeconds), privacy: .public)s audio in \(String(format: "%.2f", infer), privacy: .public)s (RTF \(String(format: "%.2f", rtf), privacy: .public)) [compute=whispercpp]"
        )
        return WhisperService.normalizedTranscription(from: raw)
    }

    /// Decodes an audio file to 16 kHz mono Float PCM (range -1...1), the input
    /// whisper.cpp expects. The app already records 16 kHz mono, but this
    /// converts defensively so it stays correct if the recording format changes.
    static func decodePCM(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat

        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
            let inBuffer = AVAudioPCMBuffer(
                pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length))
        else {
            throw WhisperService.TranscriptionError.fileNotFound
        }
        try file.read(into: inBuffer)

        // Fast path: already 16 kHz mono float — copy out directly.
        if inFormat.sampleRate == 16000, inFormat.channelCount == 1,
            inFormat.commonFormat == .pcmFormatFloat32,
            let channel = inBuffer.floatChannelData
        {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(inBuffer.frameLength)))
        }

        // Otherwise convert (sample rate / channels / format).
        guard let converter = AVAudioConverter(from: inFormat, to: targetFormat) else {
            throw WhisperService.TranscriptionError.fileNotFound
        }
        let ratio = targetFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 4096
        guard
            let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)
        else {
            throw WhisperService.TranscriptionError.fileNotFound
        }

        var fed = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inBuffer
        }
        if let convError { throw convError }

        guard let channel = outBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength)))
    }
}
