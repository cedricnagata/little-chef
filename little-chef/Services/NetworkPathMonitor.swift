//
//  NetworkPathMonitor.swift
//  little-chef
//

import Foundation
import Network

final class NetworkPathMonitor {
    static let shared = NetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkPathMonitor")
    private var currentPath: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.currentPath = path
        }
        monitor.start(queue: queue)
    }

    var isExpensive: Bool {
        guard let path = currentPath else { return false }
        return path.isExpensive || path.usesInterfaceType(.cellular)
    }
}
