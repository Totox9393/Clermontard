import ActivityKit
import Foundation

struct JourneyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let lineName: String
        let lineColorHex: String
        let lineTextColorHex: String
        let nextStop: String
        let destination: String
        let remainingStops: Int
        let phase: String
    }

    let journeyID: String
}
