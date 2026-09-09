import SwiftUI

struct SettingsView: View {
    @AppStorage(PassengerAnnouncementSettings.enabledKey) private var announcementsEnabled = false
    @StateObject private var favorites = FavoritesStore.shared
    @State private var lines: [T2CLine] = []
    @State private var stations: [NearbyStation] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Accessibilité") {
                    Toggle(isOn: $announcementsEnabled) {
                        Label("Annonces voyageurs", systemImage: "speaker.wave.2.fill")
                    }
                    .onChange(of: announcementsEnabled) { _, value in if !value { PassengerAnnouncementService.shared.stop() } }
                }
                Section("Lignes favorites") {
                    let items = lines.filter { favorites.lineIDs.contains($0.routeID) }
                    if items.isEmpty { Text("Aucune ligne favorite").foregroundStyle(.secondary) }
                    ForEach(items) { line in
                        HStack {
                            LineBadgeView(line: line, size: 40); Text("Ligne \(line.shortName)"); Spacer()
                            Button { favorites.removeLine(id: line.routeID) } label: { Image(systemName: "star.slash") }.buttonStyle(.borderless)
                        }
                    }
                }
                Section("Arrêts favoris") {
                    let items = stations.filter { favorites.stationIDs.contains($0.id) }
                    if items.isEmpty { Text("Aucun arrêt favori").foregroundStyle(.secondary) }
                    ForEach(items) { station in
                        HStack {
                            Label(station.name, systemImage: "mappin"); Spacer()
                            Button { favorites.removeStation(id: station.id) } label: { Image(systemName: "star.slash") }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            .navigationTitle("Paramètres")
            .task {
                do {
                    async let loadedLines = T2CService.shared.getLines()
                    async let loadedStations = T2CService.shared.getStations()
                    (lines, stations) = try await (loadedLines, loadedStations)
                } catch { }
            }
        }
    }
}

#Preview { SettingsView() }
