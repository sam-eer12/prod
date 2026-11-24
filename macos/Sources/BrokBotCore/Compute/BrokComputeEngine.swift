import Foundation

/// User-selectable worker concurrency target for background polling, local embeddings, and sync.
public enum ThreadAllocation: String, Codable, CaseIterable, Identifiable, Sendable, Equatable {
    case one = "1"
    case two = "2"
    case four = "4"
    case auto = "auto"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .one: return "1 Thread"
        case .two: return "2 Threads"
        case .four: return "4 Threads"
        case .auto: return "Auto"
        }
    }

    /// Resolves the effective thread count clamped to `1...max(1, processorCount)`.
    public func resolvedThreadCount(processorCount: Int = ProcessInfo.processInfo.processorCount) -> Int {
        let upperBound = max(1, processorCount)
        let requested: Int
        switch self {
        case .one: requested = 1
        case .two: requested = 2
        case .four: requested = 4
        case .auto: requested = upperBound
        }
        return max(1, min(requested, upperBound))
    }
}

/// Persistent compute & hardware acceleration preferences.
public struct ComputeConfiguration: Codable, Sendable, Equatable {
    public var threadAllocation: ThreadAllocation
    public var hardwareAccelerationEnabled: Bool

    public init(
        threadAllocation: ThreadAllocation = .auto,
        hardwareAccelerationEnabled: Bool = true
    ) {
        self.threadAllocation = threadAllocation
        self.hardwareAccelerationEnabled = hardwareAccelerationEnabled
    }
}

/// Manages local worker thread concurrency and Apple Neural Engine / Metal acceleration policy.
public final class BrokComputeEngine: @unchecked Sendable {
    public static let shared = BrokComputeEngine()

    private let lock = NSLock()
    private let workerQueue: OperationQueue
    private let processorCountProvider: @Sendable () -> Int
    private var storedConfiguration: ComputeConfiguration

    public init(
        configuration: ComputeConfiguration = ComputeConfiguration(),
        processorCountProvider: @escaping @Sendable () -> Int = { ProcessInfo.processInfo.processorCount }
    ) {
        self.storedConfiguration = configuration
        self.processorCountProvider = processorCountProvider

        let queue = OperationQueue()
        queue.name = "org.brokbot.compute"
        queue.qualityOfService = .userInitiated
        self.workerQueue = queue

        applyConfiguration(configuration)
    }

    /// Snapshot of current compute configuration.
    public var configuration: ComputeConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return storedConfiguration
    }

    /// Current effective `OperationQueue.maxConcurrentOperationCount` clamped to `1...processorCount`.
    public var maxConcurrentOperationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return workerQueue.maxConcurrentOperationCount
    }

    /// Indicates whether ANE / Metal hardware acceleration is active.
    public var hardwareAccelerationEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedConfiguration.hardwareAccelerationEnabled
    }

    /// Updates thread allocation mode and re-clamps the worker queue concurrency limit.
    public func setThreadAllocation(_ allocation: ThreadAllocation) {
        lock.lock()
        defer { lock.unlock() }
        storedConfiguration.threadAllocation = allocation
        let clamped = allocation.resolvedThreadCount(processorCount: processorCountProvider())
        workerQueue.maxConcurrentOperationCount = clamped
    }

    /// Sets an explicit thread count clamped to `1...processorCount`.
    public func setThreadCount(_ requestedThreads: Int) {
        lock.lock()
        defer { lock.unlock() }
        let upperBound = max(1, processorCountProvider())
        let clamped = max(1, min(requestedThreads, upperBound))
        workerQueue.maxConcurrentOperationCount = clamped

        switch clamped {
        case 1: storedConfiguration.threadAllocation = .one
        case 2: storedConfiguration.threadAllocation = .two
        case 4: storedConfiguration.threadAllocation = .four
        default: storedConfiguration.threadAllocation = .auto
        }
    }

    /// Enables or disables Apple Neural Engine (ANE) / Metal hardware acceleration.
    public func setHardwareAccelerationEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storedConfiguration.hardwareAccelerationEnabled = enabled
    }

    /// Schedules work on the bounded compute `OperationQueue`.
    public func enqueue(_ work: @escaping @Sendable () -> Void) {
        workerQueue.addOperation(work)
    }

    private func applyConfiguration(_ config: ComputeConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        storedConfiguration = config
        workerQueue.maxConcurrentOperationCount = config.threadAllocation.resolvedThreadCount(
            processorCount: processorCountProvider()
        )
    }
}
