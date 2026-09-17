import ActivityKit
import Foundation

@MainActor
final class JourneyLiveActivityController {
    private var activity: Activity<JourneyActivityAttributes>?
    private var lastState: JourneyActivityAttributes.ContentState?

    func update(
        journeyID: String,
        leg: T2CJourneyLeg,
        currentStopIndex: Int,
        phase: String,
        startIfNeeded: Bool = false
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let nextIndex = min(currentStopIndex + (phase == "À bord" ? 1 : 0), leg.stations.count - 1)
        let state = JourneyActivityAttributes.ContentState(
            lineName: leg.line.shortName,
            lineColorHex: leg.line.colorHex,
            lineTextColorHex: leg.line.textColorHex,
            nextStop: leg.stations.indices.contains(nextIndex) ? leg.stations[nextIndex].name : leg.destination.name,
            destination: leg.destination.name,
            remainingStops: max(leg.stations.count - currentStopIndex - 1, 0),
            phase: phase
        )
        guard activity == nil || state != lastState else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(180))

        if let activity {
            lastState = state
            Task { await activity.update(content) }
        } else if startIfNeeded {
            do {
                activity = try Activity.request(
                    attributes: JourneyActivityAttributes(journeyID: journeyID),
                    content: content,
                    pushType: nil
                )
                lastState = state
            } catch {
                print("ClermonTard Live Activity : \(error.localizedDescription)")
            }
        }
    }

    func end(finalStop: String) {
        guard let activity else { return }
        let finalState = JourneyActivityAttributes.ContentState(
            lineName: activity.content.state.lineName,
            lineColorHex: activity.content.state.lineColorHex,
            lineTextColorHex: activity.content.state.lineTextColorHex,
            nextStop: finalStop,
            destination: finalStop,
            remainingStops: 0,
            phase: "Arrivé"
        )
        self.activity = nil
        lastState = nil
        Task {
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(60))
            )
        }
    }

    func cancel() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
