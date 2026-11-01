//
//  NetworkPathMonitor.swift
//  little-chef
//
//  Whether the current connection is one a multi-gigabyte download should warn about.
//

import Foundation
import Network

final class NetworkPathMonitor: @unchecked Sendable {
    static let shared = NetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkPathMonitor")
    /// Written on `queue`, read from the main thread, so guarded.
    private let lock = NSLock()
    private var currentPath: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.currentPath = path
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    /// Cellular or otherwise metered. False when the path isn't known yet.
    var isExpensive: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let path = currentPath else { return false }
        return path.isExpensive || path.usesInterfaceType(.cellular)
    }
}
