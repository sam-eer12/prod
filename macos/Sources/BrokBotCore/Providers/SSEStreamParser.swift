import Foundation

/// A single dispatched Server-Sent Events (SSE) payload.
public struct SSEEvent: Sendable, Equatable {
    public static let doneSentinel = "[DONE]"

    public let event: String?
    public let data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }

    /// Returns `true` when the payload represents an OpenAI-style `[DONE]` stream terminator.
    public var isDoneSentinel: Bool {
        data.trimmingCharacters(in: .whitespacesAndNewlines) == Self.doneSentinel
    }
}

/// Incremental UTF-8 Server-Sent Events parser supporting arbitrary byte chunk boundaries,
/// `\r\n` / `\n` / `\r` line endings, `event:` fields, multi-line `data:` concatenation,
/// comment lines (`:`), `[DONE]` sentinel detection, and explicit end-of-stream flushing.
public struct SSEStreamParser: Sendable {
    private var byteBuffer = Data()
    private var pendingCR = false
    private var didCheckBOM = false
    private var currentEventName: String?
    private var dataLines: [String] = []

    /// Controls whether `[DONE]` sentinel events are filtered out and mark `receivedDoneSentinel`.
    public let stopOnDoneSentinel: Bool

    /// Becomes `true` once a `[DONE]` sentinel event has been observed.
    public private(set) var receivedDoneSentinel = false

    public init(stopOnDoneSentinel: Bool = true) {
        self.stopOnDoneSentinel = stopOnDoneSentinel
    }

    /// Feeds an arbitrary chunk of UTF-8 bytes and returns any complete SSE events decoded so far.
    public mutating func feed(_ chunk: Data) -> [SSEEvent] {
        if stopOnDoneSentinel && receivedDoneSentinel {
            return []
        }
        guard !chunk.isEmpty else {
            return []
        }

        byteBuffer.append(chunk)
        stripLeadingUTF8BOMIfReady(isEOF: false)

        var emitted: [SSEEvent] = []
        while let lineData = popNextCompleteLine() {
            let line = String(decoding: lineData, as: UTF8.self)
            if let event = processLine(line) {
                if handlePotentialDoneEvent(event, into: &emitted) {
                    break
                }
            }
        }
        return emitted
    }

    /// Convenience helper for feeding UTF-8 string fragments incrementally.
    public mutating func feed(_ stringChunk: String) -> [SSEEvent] {
        feed(Data(stringChunk.utf8))
    }

    /// Flushes any trailing incomplete line and buffered event at EOF.
    public mutating func finish() -> [SSEEvent] {
        if stopOnDoneSentinel && receivedDoneSentinel {
            byteBuffer.removeAll(keepingCapacity: false)
            currentEventName = nil
            dataLines.removeAll(keepingCapacity: false)
            return []
        }

        stripLeadingUTF8BOMIfReady(isEOF: true)

        var emitted: [SSEEvent] = []
        if !byteBuffer.isEmpty {
            let trailingLine = String(decoding: byteBuffer, as: UTF8.self)
            byteBuffer.removeAll(keepingCapacity: false)
            if let event = processLine(trailingLine) {
                _ = handlePotentialDoneEvent(event, into: &emitted)
            }
        }

        if !(stopOnDoneSentinel && receivedDoneSentinel), let finalEvent = dispatchBufferedEvent() {
            _ = handlePotentialDoneEvent(finalEvent, into: &emitted)
        }

        pendingCR = false
        currentEventName = nil
        dataLines.removeAll(keepingCapacity: false)
        return emitted
    }

    private mutating func stripLeadingUTF8BOMIfReady(isEOF: Bool) {
        guard !didCheckBOM else { return }
        if byteBuffer.count >= 3 {
            didCheckBOM = true
            if byteBuffer.prefix(3).elementsEqual([0xEF, 0xBB, 0xBF]) {
                byteBuffer.removeFirst(3)
            }
        } else if let first = byteBuffer.first, first != 0xEF {
            didCheckBOM = true
        } else if isEOF {
            didCheckBOM = true
        }
    }

    private mutating func popNextCompleteLine() -> Data? {
        if pendingCR {
            guard let firstByte = byteBuffer.first else {
                return nil
            }
            pendingCR = false
            if firstByte == 0x0A {
                byteBuffer.removeFirst()
            }
        }

        var index = byteBuffer.startIndex
        while index < byteBuffer.endIndex {
            let byte = byteBuffer[index]
            if byte == 0x0A { // '\n'
                let line = Data(byteBuffer[byteBuffer.startIndex..<index])
                let nextIndex = byteBuffer.index(after: index)
                byteBuffer.removeSubrange(byteBuffer.startIndex..<nextIndex)
                return line
            }
            if byte == 0x0D { // '\r'
                let line = Data(byteBuffer[byteBuffer.startIndex..<index])
                let nextIndex = byteBuffer.index(after: index)
                if nextIndex < byteBuffer.endIndex {
                    if byteBuffer[nextIndex] == 0x0A {
                        let afterCRLF = byteBuffer.index(after: nextIndex)
                        byteBuffer.removeSubrange(byteBuffer.startIndex..<afterCRLF)
                    } else {
                        byteBuffer.removeSubrange(byteBuffer.startIndex..<nextIndex)
                    }
                } else {
                    byteBuffer.removeSubrange(byteBuffer.startIndex..<nextIndex)
                    pendingCR = true
                }
                return line
            }
            index = byteBuffer.index(after: index)
        }

        return nil
    }

    private mutating func processLine(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            return dispatchBufferedEvent()
        }
        if line.hasPrefix(":") {
            // Comment / heartbeat line per SSE spec.
            return nil
        }

        let field: String
        let value: String
        if let colonIndex = line.firstIndex(of: ":") {
            field = String(line[..<colonIndex])
            let afterColon = line.index(after: colonIndex)
            var rawValue = String(line[afterColon...])
            if rawValue.hasPrefix(" ") {
                rawValue.removeFirst()
            }
            value = rawValue
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            currentEventName = value
        case "data":
            dataLines.append(value)
        case "id", "retry":
            break
        default:
            break
        }
        return nil
    }

    private mutating func dispatchBufferedEvent() -> SSEEvent? {
        guard !dataLines.isEmpty else {
            currentEventName = nil
            return nil
        }
        let payload = dataLines.joined(separator: "\n")
        let eventName = currentEventName
        currentEventName = nil
        dataLines.removeAll(keepingCapacity: true)
        return SSEEvent(event: eventName, data: payload)
    }

    private mutating func handlePotentialDoneEvent(_ event: SSEEvent, into emitted: inout [SSEEvent]) -> Bool {
        if event.isDoneSentinel {
            receivedDoneSentinel = true
            if stopOnDoneSentinel {
                byteBuffer.removeAll(keepingCapacity: false)
                currentEventName = nil
                dataLines.removeAll(keepingCapacity: false)
                return true
            }
        }
        emitted.append(event)
        return false
    }
}
