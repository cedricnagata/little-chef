import Foundation
import Combine

/// WebSocket service for real-time communication with cooking assistant
class WebSocketService: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published var isConnected = false
    @Published var connectionError: Error?

    // MARK: - Event Callbacks

    var onToken: ((String, String) -> Void)?  // (content, requestId)
    var onAudio: ((Data, Int, String) -> Void)?  // (audioData, chunkIndex, requestId)
    var onTool: ((String, String, [String: Any]?, String?, String) -> Void)?  // (status, tool, args, result, requestId)
    var onDone: ((String, CookingSession, [Command], String) -> Void)?  // (response, session, commands, requestId)
    var onError: ((WebSocketError, String) -> Void)?  // (error, requestId)

    // MARK: - Private Properties

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession!
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // Configuration
    private let webSocketURL: URL
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3
    private var reconnectTimer: Timer?

    // Request tracking
    private var currentRequestId: String?

    // MARK: - Initialization

    init(url: String = Config.webSocketURL) {
        guard let wsURL = URL(string: url) else {
            fatalError("Invalid WebSocket URL: \(url)")
        }
        self.webSocketURL = wsURL

        super.init()

        // Configure ISO8601 date decoding with flexible fractional seconds
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // ISO8601DateFormatter only handles 3 fractional seconds (.SSS)
            // Python sends 6 fractional seconds (.SSSSSS), so we need to normalize
            let normalizedDateString: String

            // Match pattern: YYYY-MM-DDTHH:mm:ss.SSSSSSZ (6 fractional seconds)
            if let regex = try? NSRegularExpression(pattern: "(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})\\.(\\d{6})(Z|[+-]\\d{2}:\\d{2})"),
               let match = regex.firstMatch(in: dateString, range: NSRange(dateString.startIndex..., in: dateString)) {

                let beforeFractional = (dateString as NSString).substring(with: match.range(at: 1))
                let fractionalSeconds = (dateString as NSString).substring(with: match.range(at: 2))
                let timezone = (dateString as NSString).substring(with: match.range(at: 3))

                // Truncate to 3 decimal places (milliseconds)
                let milliseconds = String(fractionalSeconds.prefix(3))
                normalizedDateString = "\(beforeFractional).\(milliseconds)\(timezone)"
            } else {
                normalizedDateString = dateString
            }

            // Try parsing with various formats
            let formatters = [
                // With fractional seconds (milliseconds)
                { () -> ISO8601DateFormatter in
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f
                }(),
                // Without fractional seconds
                { () -> ISO8601DateFormatter in
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime]
                    return f
                }()
            ]

            for formatter in formatters {
                if let date = formatter.date(from: normalizedDateString) {
                    return date
                }
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
        }

        // Configure JSON encoding for snake_case (for outgoing messages)
        encoder.keyEncodingStrategy = .convertToSnakeCase

        // Note: Not using automatic snake_case conversion for decoder because
        // all iOS models already have manual CodingKeys that handle the conversion
    }

    // MARK: - Connection Management

    func connect() {
        guard !isConnected else { return }

        print("🔌 Connecting to WebSocket: \(webSocketURL)")

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300 // 5 minutes
        configuration.timeoutIntervalForResource = 300

        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        webSocket = session.webSocketTask(with: webSocketURL)
        webSocket?.resume()

        receiveMessage()

        DispatchQueue.main.async {
            self.isConnected = true
            self.reconnectAttempts = 0
        }
    }

    func disconnect() {
        print("🔌 Disconnecting from WebSocket")

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        DispatchQueue.main.async {
            self.isConnected = false
        }

        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func attemptReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            print("❌ Max reconnection attempts reached")
            return
        }

        reconnectAttempts += 1
        let delay = Double(reconnectAttempts) * 2.0  // Exponential backoff: 2s, 4s, 6s

        print("🔄 Attempting reconnection #\(reconnectAttempts) in \(delay)s")

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }

    // MARK: - Message Sending

    func sendQuery(session: CookingSession, query: String, warmup: Bool = false) -> String {
        let requestId = UUID().uuidString
        currentRequestId = requestId

        let payload = QueryPayload(cookingSession: session, query: query, warmup: warmup)
        let message = WebSocketMessage(
            action: "query",
            requestId: requestId,
            payload: payload
        )

        send(message)
        return requestId
    }

    /// Send a warmup query to wake up the Lambda function (doesn't add to conversation history)
    func sendWarmupQuery(session: CookingSession) -> String {
        return sendQuery(session: session, query: "ready", warmup: true)
    }

    private func send<T: Codable>(_ message: T) {
        guard isConnected, let webSocket = webSocket else {
            print("❌ Cannot send message: Not connected")
            return
        }

        do {
            let data = try encoder.encode(message)
            let messageString = String(data: data, encoding: .utf8)!

            print("📤 Sending message: \(messageString.prefix(200))...")

            let urlMessage = URLSessionWebSocketTask.Message.string(messageString)
            webSocket.send(urlMessage) { error in
                if let error = error {
                    print("❌ Error sending message: \(error)")
                    DispatchQueue.main.async {
                        self.connectionError = error
                    }
                }
            }
        } catch {
            print("❌ Error encoding message: \(error)")
        }
    }

    // MARK: - Message Receiving

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage()  // Continue listening

            case .failure(let error):
                print("❌ WebSocket receive error: \(error)")
                DispatchQueue.main.async {
                    self.connectionError = error
                    self.isConnected = false
                }
                self.attemptReconnect()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message else {
            print("⚠️ Received non-string message")
            return
        }

        print("📥 Received WebSocket message: \(text.prefix(200))...")

        guard let data = text.data(using: .utf8) else {
            print("⚠️ Failed to convert message to data")
            return
        }

        do {
            let event = try decoder.decode(ServerEvent.self, from: data)
            print("✅ Successfully decoded event type: \(event.type)")
            processEvent(event)
        } catch {
            print("❌ Error decoding message: \(error)")
            print("📥 Raw message: \(text)")
        }
    }

    private func processEvent(_ event: ServerEvent) {
        let requestId = event.requestId
        print("🔄 Processing event type: \(event.type) with requestId: \(requestId)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            switch event.type {
            case "token":
                if let content = event.content {
                    print("📝 Triggering onToken callback")
                    self.onToken?(content, requestId)
                }

            case "audio":
                if let base64Data = event.data,
                   let audioData = Data(base64Encoded: base64Data),
                   let chunkIndex = event.chunkIndex {
                    print("🔊 Triggering onAudio callback (chunk \(chunkIndex))")
                    self.onAudio?(audioData, chunkIndex, requestId)
                }

            case "tool":
                if let status = event.status,
                   let tool = event.tool {
                    let args = event.args?.mapValues { $0.value } as? [String: Any]
                    print("🔧 Triggering onTool callback: \(tool) (\(status))")
                    self.onTool?(status, tool, args, event.result, requestId)
                }

            case "done":
                if let response = event.response,
                   let session = event.updatedSession,
                   let commands = event.commands {
                    print("✅ Triggering onDone callback")
                    self.onDone?(response, session, commands, requestId)
                } else {
                    print("⚠️ Done event missing required fields")
                }

            case "error":
                if let code = event.code,
                   let message = event.message {
                    let error = WebSocketError(code: code, message: message)
                    print("❌ Triggering onError callback: \(code) - \(message)")
                    self.onError?(error, requestId)
                }

            default:
                print("⚠️ Unknown event type: \(event.type)")
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ WebSocket connected")
        DispatchQueue.main.async {
            self.isConnected = true
            self.connectionError = nil
            self.reconnectAttempts = 0
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("🔌 WebSocket closed with code: \(closeCode.rawValue)")
        DispatchQueue.main.async {
            self.isConnected = false
        }

        // Attempt reconnection if not a normal closure
        if closeCode != .normalClosure && closeCode != .goingAway {
            attemptReconnect()
        }
    }
}
