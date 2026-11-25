import Foundation
import Network

/// Async TCP JSON-RPC 2.0 bridge communicating with the local Blender 3D addon (`127.0.0.1:9876`).
public final class BlenderBridgeClient: Sendable {
    public init() {}

    /// Executes a JSON-RPC 2.0 method against `host:port` and returns `MCPToolCallPayload`,
    /// extracting inline PNG render previews into `ChatAttachment`s when `imageBase64` is present.
    public func callMethod(
        host: String = "127.0.0.1",
        port: Int = 9876,
        method: String,
        arguments: [String: JSONValue] = [:],
        timeoutSeconds: TimeInterval = 30
    ) async throws -> MCPToolCallPayload {
        guard let portValue = UInt16(exactly: port), portValue > 0 else {
            throw MCPClientError.socketError("Invalid TCP port \(port).")
        }

        let requestPayload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .string(UUID().uuidString),
            "method": .string(method),
            "params": .object(arguments)
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lineData = try encoder.encode(requestPayload)
        lineData.append(0x0A)

        let responseData = try await sendAndReceiveLine(
            host: host,
            port: portValue,
            payload: lineData,
            timeoutSeconds: timeoutSeconds
        )

        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: responseData),
              let envelope = decoded.objectValue else {
            throw MCPClientError.decodingError("Invalid JSON-RPC response from Blender socket.")
        }

        if let errorObj = envelope["error"]?.objectValue {
            throw MCPClientError.jsonRPCError(
                code: errorObj["code"]?.intValue ?? -32000,
                message: errorObj["message"]?.stringValue ?? "Blender bridge error",
                data: errorObj["data"]
            )
        }

        let resultObj = envelope["result"]?.objectValue ?? [:]
        var attachments: [ChatAttachment] = []

        if let imageBase64 = resultObj["imageBase64"]?.stringValue, !imageBase64.isEmpty {
            let mimeType = resultObj["mimeType"]?.stringValue ?? "image/png"
            let width = resultObj["width"]?.intValue
            let height = resultObj["height"]?.intValue
            let dimLabel = (width != nil && height != nil) ? " (\(width!)×\(height!))" : ""
            attachments.append(ChatAttachment(
                mimeType: mimeType,
                filename: "blender-preview.png",
                base64Data: imageBase64,
                caption: "Blender 3D Viewport Render\(dimLabel)"
            ))

            var sanitizedResult = resultObj
            sanitizedResult.removeValue(forKey: "imageBase64")
            sanitizedResult["attachmentIncluded"] = .bool(true)
            return MCPToolCallPayload(
                outputText: JSONValue.encodeObjectString(sanitizedResult),
                isError: false,
                attachments: attachments
            )
        }

        return MCPToolCallPayload(
            outputText: JSONValue.encodeObjectString(resultObj),
            isError: false,
            attachments: attachments
        )
    }

    // MARK: - NWConnection Line Transport

    private func sendAndReceiveLine(
        host: String,
        port: UInt16,
        payload: Data,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MCPClientError.socketError("Unsupported TCP port \(port).")
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(1.0, timeoutSeconds) * 1_000_000_000))
            connection.cancel()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let state = SocketSessionState()
            let queue = DispatchQueue(label: "org.brokbot.blender.socket")

            @Sendable func receiveNextChunk() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { chunk, _, isComplete, error in
                    if let chunk, !chunk.isEmpty {
                        if let completeLine = state.appendAndPopLine(chunk) {
                            timeoutTask.cancel()
                            connection.cancel()
                            if state.claimCompletion() {
                                continuation.resume(returning: completeLine)
                            }
                            return
                        }
                    }

                    if let error {
                        timeoutTask.cancel()
                        connection.cancel()
                        if state.claimCompletion() {
                            continuation.resume(throwing: MCPClientError.socketError(error.localizedDescription))
                        }
                        return
                    }

                    if isComplete {
                        timeoutTask.cancel()
                        let remainder = state.drainRemaining()
                        connection.cancel()
                        if state.claimCompletion() {
                            if remainder.isEmpty {
                                continuation.resume(throwing: MCPClientError.socketError("Blender socket closed without a response."))
                            } else {
                                continuation.resume(returning: remainder)
                            }
                        }
                        return
                    }

                    receiveNextChunk()
                }
            }

            connection.stateUpdateHandler = { connState in
                switch connState {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { sendError in
                        if let sendError {
                            timeoutTask.cancel()
                            connection.cancel()
                            if state.claimCompletion() {
                                continuation.resume(throwing: MCPClientError.socketError(sendError.localizedDescription))
                            }
                            return
                        }
                        receiveNextChunk()
                    })
                case .failed(let error):
                    timeoutTask.cancel()
                    connection.cancel()
                    if state.claimCompletion() {
                        continuation.resume(throwing: MCPClientError.socketError("Could not connect to Blender at \(host):\(port) (\(error.localizedDescription))."))
                    }
                case .cancelled:
                    timeoutTask.cancel()
                    if state.claimCompletion() {
                        continuation.resume(throwing: MCPClientError.socketError("Blender socket connection cancelled or timed out at \(host):\(port)."))
                    }
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }
}

private final class SocketSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var buffer = Data()

    func claimCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if completed { return false }
        completed = true
        return true
    }

    func appendAndPopLine(_ chunk: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        guard let newlineIdx = buffer.firstIndex(of: 0x0A) else {
            return nil
        }
        let line = Data(buffer[buffer.startIndex..<newlineIdx])
        buffer.removeSubrange(buffer.startIndex...newlineIdx)
        return line
    }

    func drainRemaining() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let out = buffer
        buffer.removeAll()
        return out
    }
}
