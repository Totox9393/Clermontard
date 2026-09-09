import Foundation
import Combine

@MainActor final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()
    @Published private(set) var lineIDs: Set<String>
    @Published private(set) var stationIDs: Set<String>
    private let defaults = UserDefaults.standard
    private init() {
        lineIDs = Set(defaults.stringArray(forKey: "favoriteLineIDs") ?? [])
        stationIDs = Set(defaults.stringArray(forKey: "favoriteStationIDs") ?? [])
    }
    func isLineFavorite(_ line: T2CLine) -> Bool { lineIDs.contains(line.routeID) }
    func isStationFavorite(_ station: NearbyStation) -> Bool { stationIDs.contains(station.id) }
    func toggle(line: T2CLine) {
        if lineIDs.remove(line.routeID) == nil { lineIDs.insert(line.routeID) }
        defaults.set(lineIDs.sorted(), forKey: "favoriteLineIDs")
    }
    func toggle(station: NearbyStation) {
        if stationIDs.remove(station.id) == nil { stationIDs.insert(station.id) }
        defaults.set(stationIDs.sorted(), forKey: "favoriteStationIDs")
    }
    func removeLine(id: String) { lineIDs.remove(id); defaults.set(lineIDs.sorted(), forKey: "favoriteLineIDs") }
    func removeStation(id: String) { stationIDs.remove(id); defaults.set(stationIDs.sorted(), forKey: "favoriteStationIDs") }
}
