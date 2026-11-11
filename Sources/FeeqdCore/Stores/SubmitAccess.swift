import Foundation
import os

/// What tapping "+" does for this user: there is no "+" at all, it opens the form, or it says
/// the app keeps new requests for some of its users.
package enum SubmitAccess: Equatable, Sendable {
    case hidden, form, blocked

    /// The dashboard first: with new requests turned off, or the team's plan full, there is no
    /// "+". Then the app's own say (`Feeqd.setCanSubmit`), true or false, which only ever turns
    /// the form into the alert. Left unsaid, the dashboard's "only paying users" switch decides
    /// by `pays`, nil when the SDK has no way to know who pays: then the switch does nothing, so
    /// a team can't lock out a whole app that never shares purchases. Votes and comments never ask.
    package static func resolve(config: SDKConfig, canSubmit: Bool?, pays: Bool?) -> SubmitAccess {
        guard config.behaviour.submitEnabled, config.acceptingEntries else { return .hidden }
        if let canSubmit { return canSubmit ? .form : .blocked }
        if config.behaviour.submitPaidOnly, let pays { return pays ? .form : .blocked }
        return .form
    }
}

/// What the app has said about this user: whether they may add requests (set at launch, and
/// changed while it runs, a user who subscribes mid-session) and whether they pay. Only the app
/// knows either, so the server never hears of it.
package final class SubmitGate: Sendable {
    /// Posted on the main actor when the answer changes, so a screen on display redraws its "+".
    package static let didChange = Notification.Name("com.feeqd.feeqdkit.canSubmitChanged")

    package struct State: Equatable, Sendable {
        /// Nil until the app says: the dashboard decides.
        package var canSubmit: Bool?
        /// Nil while the SDK has no way to know: purchases aren't read and the app never passed
        /// a payment.
        package var pays: Bool?

        package init(canSubmit: Bool? = nil, pays: Bool? = nil) {
            self.canSubmit = canSubmit
            self.pays = pays
        }
    }

    private let state: OSAllocatedUnfairLock<State>

    /// `readsPurchases`: the SDK reads App Store purchases, so it knows from the start; until
    /// the first read answers, the user counts as not paying.
    package init(canSubmit: Bool? = nil, readsPurchases: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(canSubmit: canSubmit, pays: readsPurchases ? false : nil))
    }

    package var current: State { state.withLock { $0 } }
    package var canSubmit: Bool? { current.canSubmit }
    package var pays: Bool? { current.pays }

    /// Nil hands the decision back to the dashboard.
    package func set(_ canSubmit: Bool?) {
        update { $0.canSubmit = canSubmit }
    }

    /// A payment read or passed in. From then on the SDK knows who pays, for the rest of the run.
    package func setPays(_ pays: Bool) {
        update { $0.pays = pays }
    }

    private func update(_ change: @Sendable (inout State) -> Void) {
        let changed = state.withLock { current -> Bool in
            let before = current
            change(&current)
            return current != before
        }
        guard changed else { return }
        Task { @MainActor in NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
}
