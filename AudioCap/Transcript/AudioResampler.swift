import AVFoundation
import Accelerate

/// Converts audio from the source format (e.g. 48kHz stereo float32)
/// to the target format for ASR (16kHz mono int16 PCM).
final class AudioResampler: @unchecked Sendable {

    let sourceFormat: AVAudioFormat
    let targetSampleRate: Double
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat

    init(sourceFormat: AVAudioFormat, targetSampleRate: Double = 16000) throws {
        self.sourceFormat = sourceFormat
        self.targetSampleRate = targetSampleRate

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw "Failed to create target audio format"
        }
        self.targetFormat = target

        guard let conv = AVAudioConverter(from: sourceFormat, to: target) else {
            throw "Failed to create audio converter from \(sourceFormat) to \(target)"
        }
        self.converter = conv
    }

    /// Convert an AVAudioPCMBuffer to 16kHz mono int16 PCM Data.
    /// Returns nil if conversion fails.
    func convert(_ inputBuffer: AVAudioPCMBuffer) -> Data? {
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)

        guard outputFrameCount > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return nil }

        var error: NSError?
        var hasData = true

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return inputBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if let error {
            // Log but don't crash — audio glitches are acceptable
            _ = error
            return nil
        }

        guard outputBuffer.frameLength > 0 else { return nil }

        // Extract int16 samples as raw bytes
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        guard let int16Ptr = outputBuffer.int16ChannelData?[0] else { return nil }
        return Data(bytes: int16Ptr, count: byteCount)
    }
}
