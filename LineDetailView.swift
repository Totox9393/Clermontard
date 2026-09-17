import SwiftUI

/// The line journey always starts with a station, retaining both directions.
struct LineDetailView: View {
    let line: T2CLine
    var body: some View {
        LineStopsView(line: line)
            .navigationTitle("Ligne \(line.shortName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

struct LineStopsView: View {
    let line: T2CLine
    var selectedStationID: String? = nil
    var onSelect: ((NearbyStation) -> Void)? = nil
    @State private var stations: [NearbyStation] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?
    @StateObject private var favorites = FavoritesStore.shared

    private var results: [NearbyStation] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = value.isEmpty ? stations : stations.filter { StationSearch.matches($0.name, query: value) }
        return filtered.sorted {
            let a = favorites.isStationFavorite($0), b = favorites.isStationFavorite($1)
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 18) {
                    LineBadgeView(line: line, size: 104)
                    Text("D’où partez-vous ?").font(.title.bold())
                    Text("Choisissez un arrêt pour voir les passages dans les deux sens.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
                SearchField(placeholder: "Rechercher un arrêt de la ligne", text: $query)
                if loading { ProgressView("Chargement des arrêts…") }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Réessayer") { Task { await load() } }
                }
                if !loading && error == nil && results.isEmpty {
                    ContentUnavailableView("Aucun arrêt trouvé", systemImage: "mappin.slash", description: Text("Essayez un autre nom d’arrêt."))
                }
                LazyVStack(spacing: 0) {
                    ForEach(results) { station in
                        HStack(spacing: 6) {
                            if let onSelect {
                                Button { onSelect(station) } label: { row(station) }.buttonStyle(.plain)
                            } else {
                                NavigationLink { StationLineView(station: station, line: line) } label: { row(station) }.buttonStyle(.plain)
                            }
                            Button { favorites.toggle(station: station) } label: {
                                Image(systemName: favorites.isStationFavorite(station) ? "star.fill" : "star")
                                    .font(.title3).foregroundStyle(favorites.isStationFavorite(station) ? Color.yellow : .secondary)
                                    .frame(width: 44, height: 44)
                            }
                        }
                        Divider()
                    }
                }
            }.padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .scrollDismissesKeyboard(.interactively)
        .task { await load() }
    }

    private func row(_ station: NearbyStation) -> some View {
        HStack(spacing: 14) {
            Image(systemName: line.isTram ? "tram.fill" : "bus.fill").foregroundStyle(.secondary)
            Text(station.name).font(.body.weight(.medium))
            Spacer()
            Image(systemName: station.id == selectedStationID ? "checkmark" : "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }.padding(.vertical, 15).contentShape(Rectangle()).frame(maxWidth: .infinity)
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            stations = try await T2CService.shared.getStations().filter { station in
                station.lines.contains { $0.routeID == line.routeID }
            }
        } catch { self.error = "Impossible de charger les arrêts. Vérifiez votre connexion." }
    }
}
