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
        // Latency metrics from server
        let processing_ms: Double?
        let correction_ms: Double?
        let client_audio_ts: Double?  // server recv timestamp, for RTT calc
    }

    let serverURL: URL
    private let logger = Logger(subsystem: kAppSubsystem, category: "WebSocketStreamer")

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private(set) var isConnected = false
    private(set) var segments: [Int: TranscriptSegment] = [:]
    private(set) var errorMessage: String?

    // Latency stats
    private(set) var lastProcessingMs: Double = 0
    private(set) var lastCorrectionMs: Double = 0
    private(set) var lastRoundTripMs: Double = 0
    private let timestampLock = NSLock()
    private var chunkSendTimestamps: [Int: CFAbsoluteTime] = [:]  // seq -> send time
    private var audioChunkSeq = 0

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
        let sendTime = CFAbsoluteTimeGetCurrent()
        timestampLock.lock()
        audioChunkSeq += 1
        let seq = audioChunkSeq
        // Keep only recent timestamps to avoid memory growth
        if seq % 100 == 0 {
            let cutoff = seq - 200
            chunkSendTimestamps = chunkSendTimestamps.filter { $0.key > cutoff }
        }
        chunkSendTimestamps[seq] = sendTime
        timestampLock.unlock()
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
        // Update latency metrics
        if let pms = event.processing_ms {
            lastProcessingMs = pms
        }
        if let cms = event.correction_ms {
            lastCorrectionMs = cms
        }

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
            logLatency(event: event, type: event.type)

        case "final":
            guard let segID = event.segment_id, let text = event.text else { return }
            segments[segID] = TranscriptSegment(
                id: segID,
                text: text,
                isFinal: true,
                language: event.language ?? ""
            )
            logLatency(event: event, type: "final")

        case "error":
            let msg = "\(event.code ?? "ERROR"): \(event.message ?? "Unknown error")"
            logger.error("Server error: \(msg, privacy: .public)")
            setError(msg)

        default:
            break
        }
    }

    private func logLatency(event: TranscriptEvent, type: String) {
        let recvTime = CFAbsoluteTimeGetCurrent()
        // Estimate RTT: use the most recent chunk send time as approximation
        // (The server echoes its recv timestamp as client_audio_ts, but since
        // clocks differ, we use the last send time for local RTT estimation)
        timestampLock.lock()
        let lastSendTime: CFAbsoluteTime? = chunkSendTimestamps.keys.max().flatMap { chunkSendTimestamps[$0] }
        timestampLock.unlock()
        if let sendTime = lastSendTime {
            let rttMs = (recvTime - sendTime) * 1000
            lastRoundTripMs = rttMs
            logger.info(
                "[\(type, privacy: .public)] processing=\(event.processing_ms ?? 0, privacy: .public)ms correction=\(event.correction_ms ?? 0, privacy: .public)ms rtt≈\(String(format: "%.1f", rttMs), privacy: .public)ms text=\(event.text ?? "", privacy: .public)"
            )
        } else {
            logger.info(
                "[\(type, privacy: .public)] processing=\(event.processing_ms ?? 0, privacy: .public)ms text=\(event.text ?? "", privacy: .public)"
            )
        }
    }

    private func setError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = message
        }
    }
}
