#if os(iOS) && canImport(ActivityKit)
@preconcurrency import ActivityKit
import Foundation

@MainActor
final class TrackingLiveActivityController {
    private var activity: Activity<AtlasTrackingAttributes>?
    private var pendingUpdateTask: Task<Void, Never>?
    private var pendingState: AtlasTrackingAttributes.ContentState?
    private var lastUpdateAt: Date?
    private var lifecycleGeneration = UUID()
    private let minimumUpdateInterval: TimeInterval = 4

    func start(
        attributes: AtlasTrackingAttributes,
        state: AtlasTrackingAttributes.ContentState
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        pendingState = nil
        let generation = UUID()
        lifecycleGeneration = generation

        Task {
            for existing in Activity<AtlasTrackingAttributes>.activities {
                await existing.end(
                    ActivityContent(state: state, staleDate: nil),
                    dismissalPolicy: .immediate
                )
            }
            do {
                let requestedActivity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(
                        state: state,
                        staleDate: Date.now.addingTimeInterval(90)
                    )
                )
                guard lifecycleGeneration == generation else {
                    await requestedActivity.end(
                        ActivityContent(state: state, staleDate: nil),
                        dismissalPolicy: .immediate
                    )
                    return
                }
                activity = requestedActivity
                lastUpdateAt = .now
            } catch {
                if lifecycleGeneration == generation {
                    activity = nil
                }
            }
        }
    }

    func update(
        _ state: AtlasTrackingAttributes.ContentState,
        immediately: Bool = false
    ) {
        guard activity != nil else { return }
        pendingState = state
        let elapsed = lastUpdateAt.map { Date.now.timeIntervalSince($0) } ?? .infinity
        if immediately || elapsed >= minimumUpdateInterval {
            publishPendingState()
            return
        }

        pendingUpdateTask?.cancel()
        pendingUpdateTask = Task { [weak self] in
            let delay = max(0, (self?.minimumUpdateInterval ?? 0) - elapsed)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.publishPendingState() }
        }
    }

    func end(
        finalState: AtlasTrackingAttributes.ContentState?,
        immediately: Bool = true
    ) {
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        pendingState = nil
        lifecycleGeneration = UUID()
        guard let activity else { return }
        self.activity = nil

        Task {
            let state = finalState ?? activity.content.state
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: immediately ? .immediate : .after(.now.addingTimeInterval(60))
            )
        }
    }

    private func publishPendingState() {
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        guard let activity, let pendingState else { return }
        self.pendingState = nil
        lastUpdateAt = .now
        Task {
            await activity.update(ActivityContent(
                state: pendingState,
                staleDate: Date.now.addingTimeInterval(90)
            ))
        }
    }
}
#endif
