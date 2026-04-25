import Foundation
import Combine

/// Aggregates the set of active sessions into a single `BuddyMood` that
/// drives the pixel buddy's color and behavior.
///
/// Priority (highest → lowest):
///   attention  (any session waitingForApproval or waitingForQuestion)
///   tooling    (any session status == "running_tool")  — tracked via phase.description
///   thinking   (any session .processing)
///   waiting    (any session .waitingForInput)
///   idle       (otherwise, or no sessions)
///
/// Error mood is TBD — hook events don't carry a dedicated error phase in
/// the MVP state machine; when that's added, extend `mood(for:)`.
@MainActor
final class BuddyBrain: ObservableObject {
    @Published private(set) var currentMood: BuddyMood = .idle
    @Published private(set) var sessions: [String: SessionState] = [:]

    /// Transient mood override. When set, views render this instead of
    /// `currentMood`. Used for short flashes (e.g. green on task
    /// completion) that would otherwise be swallowed by the priority
    /// ladder if another session is still processing.
    @Published private(set) var flashMood: BuddyMood?

    /// Rendering aggregate: flash wins over the steady-state mood.
    var displayMood: BuddyMood { flashMood ?? currentMood }

    func flash(_ mood: BuddyMood, for seconds: TimeInterval = 1.0) {
        flashMood = mood
        let token = UUID()
        flashToken = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.flashToken == token else { return }
            self.flashMood = nil
        }
    }

    private var flashToken: UUID?

    /// Fired when `currentMood` becomes `.attention`. Room for the
    /// `RoamingCoordinator` to summon the buddy to the cursor screen.
    var onAttentionNeeded: (() -> Void)?

    private var cancellable: AnyCancellable?

    init(store: SessionStore) {
        // Seed from the store's current snapshot.
        self.sessions = store.sessions
        self.currentMood = BuddyBrain.mood(for: store.sessions.values.map(\.phase))

        // Both store and brain are @MainActor-isolated, so $structuralRevision
        // already publishes on main; no receive(on:) hop required.
        // Subscribe to structural-only changes so heartbeats don't trigger
        // a full mood recomputation.
        cancellable = store.$structuralRevision
            .dropFirst()                                    // skip initial value
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                self.sessions = store.sessions
                let next = BuddyBrain.mood(for: store.sessions.values.map(\.phase))
                let wasAttention = self.currentMood == .attention
                self.currentMood = next
                if next == .attention, !wasAttention {
                    self.onAttentionNeeded?()
                }
            }
    }

    /// Pure aggregation — no instance state; testable without a store.
    static func mood(for phases: [SessionPhase]) -> BuddyMood {
        if phases.isEmpty { return .idle }
        if phases.contains(where: { $0.isWaitingForApproval || $0.isWaitingForQuestion }) {
            return .attention
        }
        if phases.contains(where: { if case .processing = $0 { return true }; return false }) {
            return .thinking
        }
        if phases.contains(.waitingForInput) { return .waiting }
        return .idle
    }
}
