import FeeqdCore
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// Keeps the client's App Store figure current: read at launch and whenever the app comes back
/// to the foreground, which is when a purchase, upgrade or cancellation is likely to show.
enum PurchaseWatcher {
    // `unchecked`: the observer token is not Sendable, but it is only ever handed to
    // NotificationCenter, from inside the lock.
    private static let observer = OSAllocatedUnfairLock<NSObjectProtocol?>(uncheckedState: nil)

    static func start(client: FeeqdClient) {
        refresh(client)
        #if canImport(UIKit)
        let token = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { _ in refresh(client) }
        observer.withLockUnchecked { old in
            if let old { NotificationCenter.default.removeObserver(old) }
            old = token
        }
        #endif
    }

    private static func refresh(_ client: FeeqdClient) {
        Task.detached(priority: .utility) {
            // Read before StoreKit answers: a `reset()` meanwhile makes this answer stale.
            let generation = await client.paymentGeneration
            let payment = await StoreKitPayments.current()
            await client.setStorePayment(payment, generation: generation)
        }
    }
}
