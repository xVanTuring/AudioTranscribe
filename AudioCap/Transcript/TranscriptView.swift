import SwiftUI

/// Displays real-time transcript segments from the live-transcript server.
@MainActor
struct TranscriptView: View {
    let streamer: WebSocketStreamer

    var body: some View {
        Section {
            if let error = streamer.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if streamer.orderedSegments.isEmpty && streamer.isConnected {
                Text("Listening…")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(attributedTranscript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 60, maxHeight: 200)
            }
        } header: {
            HStack {
                Image(systemName: streamer.isConnected ? "waveform.circle.fill" : "waveform.circle")
                    .foregroundStyle(streamer.isConnected ? .green : .secondary)
                Text("Live Transcript")
                    .font(.headline)
            }
        }
    }

    private var attributedTranscript: AttributedString {
        var result = AttributedString()
        let segments = streamer.orderedSegments

        for (index, segment) in segments.enumerated() {
            var part = AttributedString(segment.text)
            if segment.isFinal {
                part.foregroundColor = .primary
            } else {
                part.foregroundColor = .secondary
            }
            result.append(part)
            if index < segments.count - 1 {
                result.append(AttributedString(" "))
            }
        }

        return result
    }
}
