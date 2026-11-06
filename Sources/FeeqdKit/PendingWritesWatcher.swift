import FeeqdCore
import Foundation
import Network
import os
#if canImport(UIKit)
import UIKit
#endif

/// Sends what the user wrote and could not send: at launch, when the app comes back to the
/// foreground, and when the device gets a connection again.
enum PendingWritesWatcher {
    // `unchecked`: the observer token is not Sendable, but it is only ever handed to
    // NotificationCenter, from inside the lock.
    private static let observer = OSAllocatedUnfairLock<NSObjectProtocol?>(uncheckedState: nil)
    private static let monitor = OSAllocatedUnfairLock<NWPathMonitor?>(initialState: nil)

    static func start(client: FeeqdClient) {
        send(client)
        #if canImport(UIKit)
        let token = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { _ in send(client) }
        observer.withLockUnchecked { old in
            if let old { NotificationCenter.default.removeObserver(old) }
            old = token
        }
        #endif
        let paths = NWPathMonitor()
        paths.pathUpdateHandler = { path in
            if path.status == .satisfied { send(client) }
        }
        paths.start(queue: DispatchQueue(label: "com.feeqd.feeqdkit.paths", qos: .utility))
        monitor.withLock { old in
            old?.cancel()
            old = paths
        }
    }

    private static func send(_ client: FeeqdClient) {
        Task.detached(priority: .utility) { await client.sendPendingWrites() }
    }
}
