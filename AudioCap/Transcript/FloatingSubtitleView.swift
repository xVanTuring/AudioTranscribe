import SwiftUI

/// SwiftUI content view hosted inside the floating subtitle panel.
@MainActor
struct FloatingSubtitleView: View {
    let streamer: WebSocketStreamer
    let panel: FloatingSubtitlePanel

    @State private var alwaysOnTop = true

    var body: some View {
        VStack(spacing: 4) {
            // Toolbar
            HStack {
                Toggle("Always on Top", isOn: $alwaysOnTop)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .onChange(of: alwaysOnTop) { _, newValue in
                        panel.setAlwaysOnTop(newValue)
                    }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Subtitle text
            ScrollViewReader { proxy in
                ScrollView {
                    Text(attributedTranscript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .onChange(of: streamer.orderedSegments.last?.text) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: streamer.orderedSegments.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(minWidth: 300, minHeight: 60)
    }

    private var attributedTranscript: AttributedString {
        var result = AttributedString()
        let segments = streamer.orderedSegments

        if segments.isEmpty {
            var listening = AttributedString("Listening...")
            listening.foregroundColor = .white.opacity(0.5)
            return listening
        }

        for (index, segment) in segments.enumerated() {
            var part = AttributedString(segment.text)
            part.foregroundColor = segment.isFinal ? .white : .white.opacity(0.6)
            part.font = .system(size: 18, weight: segment.isFinal ? .medium : .regular)
            result.append(part)
            if index < segments.count - 1 {
                result.append(AttributedString(" "))
            }
        }

        return result
    }
}
