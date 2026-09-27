import Foundation

/// Runs blocking work (network requests that wait on a semaphore, file coordination,
/// audio rendering) on a GCD queue. Swift's own task threads are only as many as the
/// phone has cores: blocking them (a Takes tab syncing every song, an upload, the
/// library sync) left nothing to open a song with, and it stayed on "Loading tracks…".
enum Background {
    static func run<T>(_ qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: qos).async { cont.resume(with: Result { try work() }) }
        }
    }

    static func get<T>(_ qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: qos).async { cont.resume(returning: work()) }
        }
    }
}
