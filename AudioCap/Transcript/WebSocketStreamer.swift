import Foundation
import OSLog

/// Manages a WebSocket connection to the live-transcript server,
/// streaming PCM audio and receiving transcript events.
@Observable
final class WebSocketStreamer: @unchecked Sendable {

    struct TranscriptSegment: Identifiable {
        let id: Int  // segment_id
        var text: String
        var isFinal: Bool
        var language: String
    }

    struct TranscriptEvent: Decodable {
        let type: String
        let segment_id: Int?
        let text: String?
        let previous_text: String?
        let language: String?
        let code: String?
        let message: String?
    }

    let serverURL: URL
    private let logger = Logger(subsystem: kAppSubsystem, category: "WebSocketStreamer")

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private(set) var isConnected = false
    private(set) var segments: [Int: TranscriptSegment] = [:]
    private(set) var errorMessage: String?

    /// Ordered segments for display.
    var orderedSegments: [TranscriptSegment] {
        segments.keys.sorted().compactMap { segments[$0] }
    }

    /// Full transcript text.
    var fullText: String {
        orderedSegments.map(\.text).joined(separator: " ")
    }

    init(serverURL: URL = URL(string: "ws://127.0.0.1:8765/ws/transcribe")!) {
        self.serverURL = serverURL
    }

    // MARK: - Connection

    func connect(sampleRate: Int = 16000) {
        guard !isConnected else { return }

        logger.info("Connecting to \(self.serverURL.absoluteString)")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: serverURL)

        self.urlSession = session
        self.webSocketTask = task
        self.errorMessage = nil
        self.segments = [:]

        task.resume()

        // Send start message
        let startMessage: [String: Any] = [
            "type": "start",
            "config": [
                "sample_rate": sampleRate,
                "encoding": "pcm_s16le",
                "channels": 1,
                "language": "auto",
                "enable_correction": true
            ] as [String: Any]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: startMessage),
           let text = String(data: data, encoding: .utf8) {
            task.send(.string(text)) { [weak self] error in
                if let error {
                    self?.logger.error("Failed to send start: \(error, privacy: .public)")
                    self?.setError("Failed to send start: \(error.localizedDescription)")
                }
            }
        }

        isConnected = true
        receiveLoop()
    }

    func disconnect() {
        guard isConnected else { return }

        logger.info("Disconnecting")

        // Send stop message
        let stopMessage = "{\"type\":\"stop\"}"
        webSocketTask?.send(.string(stopMessage)) { _ in }

        // Close after a short delay to allow final messages
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.webSocketTask?.cancel(with: .normalClosure, reason: nil)
            self?.webSocketTask = nil
            self?.urlSession?.invalidateAndCancel()
            self?.urlSession = nil
            self?.isConnected = false
        }
    }

    // MARK: - Send Audio

    /// Send raw PCM s16le audio data over WebSocket.
    /// Call this from the audio I/O callback (any thread).
    func sendAudio(_ data: Data) {
        guard let task = webSocketTask, isConnected else { return }
        task.send(.data(data)) { [weak self] error in
            if let error {
                self?.logger.error("Send audio error: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Receive

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Continue receiving
                self.receiveLoop()

            case .failure(let error):
                self.logger.error("Receive error: \(error, privacy: .public)")
                DispatchQueue.main.async {
                    self.isConnected = false
                    if (error as NSError).code != 57 { // Not "socket is not connected"
                        self.setError("Connection lost: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(TranscriptEvent.self, from: data) else {
            logger.warning("Failed to decode message: \(text, privacy: .public)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.applyEvent(event)
        }
    }

    private func applyEvent(_ event: TranscriptEvent) {
        switch event.type {
        case "ready":
            logger.info("Server ready")
            errorMessage = nil

        case "partial", "correction":
            guard let segID = event.segment_id, let text = event.text else { return }
            segments[segID] = TranscriptSegment(
                id: segID,
                text: text,
                isFinal: false,
                language: event.language ?? ""
            )

        case "final":
            guard let segID = event.segment_id, let text = event.text else { return }
            segments[segID] = TranscriptSegment(
                id: segID,
                text: text,
                isFinal: true,
                language: event.language ?? ""
            )

        case "error":
            let msg = "\(event.code ?? "ERROR"): \(event.message ?? "Unknown error")"
            logger.error("Server error: \(msg, privacy: .public)")
            setError(msg)

        default:
            break
        }
    }

    private func setError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = message
        }
    }
}
