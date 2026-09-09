import SwiftUI

struct ThermometerView: View {
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    @State private var lines: [T2CLine] = []
    @State private var stations: [NearbyStation] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?
    @StateObject private var favorites = FavoritesStore.shared

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sortedLines: [T2CLine] {
        lines.sorted {
            let left = favorites.isLineFavorite($0)
            let right = favorites.isLineFavorite($1)
            return left == right
                ? $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
                : left
        }
    }

    private var matchingLines: [T2CLine] {
        sortedLines.filter {
            $0.shortName.localizedStandardContains(query) || $0.longName.localizedStandardContains(query)
        }
    }

    private var matchingStations: [NearbyStation] {
        stations.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Label("Parcours et arrêts de chaque ligne", systemImage: "list.bullet.below.rectangle")
                        .font(.subheadline).foregroundStyle(.secondary)
                    SearchField(placeholder: "Rechercher une ligne ou un arrêt", text: $query)

                    if loading && lines.isEmpty { ProgressView("Chargement des lignes…") }
                    if let error {
                        Text(error).foregroundStyle(.secondary)
                        Button("Réessayer") { Task { await load() } }
                    }

                    if searching {
                        searchResults
                    } else {
                        lineGrid
                    }
                }
                .padding(24).frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
            .navigationTitle("Thermomètre")
            .background(Color(uiColor: .systemBackground))
            .task { if lines.isEmpty { await load() } }
            .refreshable { await load() }
        }
    }

    private let categories = ["Favoris", "Tram et lignes principales", "Essentielles", "Structurantes", "Proximité", "Autres lignes"]

    @ViewBuilder private var lineGrid: some View {
        ForEach(categories, id: \.self) { category in
            let group = sortedLines.filter { categoryFor($0) == category }
            if !group.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text(category).font(.headline)
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(group) { line in
                            lineLink(line)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        if matchingLines.isEmpty && matchingStations.isEmpty && !loading {
            ContentUnavailableView(
                "Aucun résultat",
                systemImage: "magnifyingglass",
                description: Text("Essayez le nom d’un arrêt ou le numéro d’une ligne.")
            )
        }

        if !matchingStations.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                Text("ARRÊTS TROUVÉS")
                    .font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
                ForEach(matchingStations) { station in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(station.name).font(.headline)
                        ForEach(station.lines.sorted {
                            $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
                        }) { line in
                            NavigationLink {
                                LineThermometerView(line: line, highlightedStopName: station.name)
                            } label: {
                                StopLineSearchResult(line: line, stopName: station.name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }

        if !matchingLines.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("LIGNES TROUVÉES")
                    .font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(matchingLines) { line in lineLink(line) }
                }
            }
        }
    }

    private func lineLink(_ line: T2CLine) -> some View {
        NavigationLink {
            LineThermometerView(line: line)
        } label: {
            VStack(spacing: 8) {
                LineBadgeView(line: line, size: 64)
                Image(systemName: "arrow.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color(hex: line.colorHex))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { favorites.toggle(line: line) } label: {
                Label(
                    favorites.isLineFavorite(line) ? "Retirer des favoris" : "Ajouter aux favoris",
                    systemImage: favorites.isLineFavorite(line) ? "star.slash" : "star"
                )
            }
        }
    }
    private func categoryFor(_ line: T2CLine) -> String {
        if favorites.isLineFavorite(line) { return "Favoris" }
        if ["A", "B", "C"].contains(line.shortName) { return "Tram et lignes principales" }
        if line.shortName.hasPrefix("E") { return "Essentielles" }
        if line.shortName.hasPrefix("S") { return "Structurantes" }
        if line.shortName.hasPrefix("P") { return "Proximité" }
        return "Autres lignes"
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            lines = try await T2CService.shared.getLines()
            stations = try await T2CService.shared.getStations()
        }
        catch { self.error = "Impossible de charger les lignes." }
    }
}

private struct StopLineSearchResult: View {
    let line: T2CLine
    let stopName: String

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 0) {
                Rectangle().fill(lineColor.opacity(0.55)).frame(width: 3, height: 15)
                Circle().fill(lineColor).frame(width: 12, height: 12)
                    .overlay { Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 3) }
                Rectangle().fill(lineColor.opacity(0.55)).frame(width: 3, height: 15)
            }
            LineBadgeView(line: line, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(stopName).font(.subheadline.weight(.semibold))
                Text("Desservi par la ligne \(line.shortName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var lineColor: Color { Color(hex: line.colorHex) }
}

struct LineThermometerView: View {
    let line: T2CLine
    var highlightedStopName: String? = nil
    @State private var groups: [ThermometerDirection] = []
    @State private var selectedID = ""
    @State private var loading = true
    @State private var error: String?

    private var selectedGroup: ThermometerDirection? {
        groups.first { $0.id == selectedID } ?? groups.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 16) {
                    LineBadgeView(line: line, size: 104)
                    Text("Thermomètre de la ligne")
                        .font(.title2.bold())
                }.frame(maxWidth: .infinity).padding(.top, 12)

                if loading { ProgressView("Construction du parcours…") }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Réessayer") { Task { await load() } }
                }

                if groups.count > 1 {
                    Picker("Sens", selection: $selectedID) {
                        ForEach(groups) { group in
                            Text(group.label).tag(group.id)
                        }
                    }.pickerStyle(.segmented)
                }

                if let group = selectedGroup {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("TERMINUS POSSIBLES")
                            .font(.caption2.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
                        Text(group.terminusNames.joined(separator: " · "))
                            .font(.headline)
                    }

                    let stops = mergedStops(group)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                            ThermometerStopRow(
                                stop: stop,
                                color: Color(hex: line.colorHex),
                                drawsLine: index < stops.count - 1,
                                highlighted: highlightedStopName.map {
                                    stop.name.localizedStandardContains($0)
                                } ?? false
                            )
                        }
                    }
                } else if !loading && error == nil {
                    ContentUnavailableView("Parcours indisponible", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .navigationTitle("Ligne \(line.shortName)")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemBackground))
        .task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let directions = try await T2CService.shared.getDirections(for: line.routeID)
            var variants: [ThermometerVariant] = []
            for direction in directions {
                let stops = try await T2CService.shared.getStops(for: line.routeID, direction: direction)
                if !stops.isEmpty { variants.append(ThermometerVariant(direction: direction, stops: stops)) }
            }
            groups = Dictionary(grouping: variants, by: { $0.direction.directionID })
                .map { id, variants in ThermometerDirection(id: id, variants: variants) }
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            if let highlightedStopName,
               let matchingGroup = groups.first(where: { group in
                   group.variants.contains { variant in
                       variant.stops.contains { $0.name.localizedStandardContains(highlightedStopName) }
                   }
               }) {
                selectedID = matchingGroup.id
            } else {
                selectedID = groups.first?.id ?? ""
            }
        } catch { self.error = "Impossible de construire le parcours de cette ligne." }
    }

    private func mergedStops(_ group: ThermometerDirection) -> [ThermometerStop] {
        var values: [String: StopAccumulator] = [:]
        for variant in group.variants {
            let lastIndex = max(variant.stops.count - 1, 1)
            for (index, stop) in variant.stops.enumerated() {
                let key = stop.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                var value = values[key] ?? StopAccumulator(name: stop.name)
                value.positions.append(Double(index) / Double(lastIndex))
                value.isTerminus = value.isTerminus || index == 0 || index == variant.stops.count - 1
                values[key] = value
            }
        }
        return values.map { key, value in
            ThermometerStop(
                id: key,
                name: value.name,
                position: value.positions.reduce(0, +) / Double(value.positions.count),
                isTerminus: value.isTerminus
            )
        }.sorted { $0.position == $1.position ? $0.name < $1.name : $0.position < $1.position }
    }
}

private struct ThermometerStopRow: View {
    let stop: ThermometerStop
    let color: Color
    let drawsLine: Bool
    let highlighted: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                Circle()
                    .fill(stop.isTerminus ? color : Color(uiColor: .systemBackground))
                    .overlay { Circle().stroke(color, lineWidth: 3) }
                    .frame(width: 15, height: 15)
                if drawsLine { Rectangle().fill(color.opacity(0.55)).frame(width: 3, height: 42) }
            }.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(stop.name).font(stop.isTerminus ? .body.bold() : .body)
                if stop.isTerminus { Text("Terminus").font(.caption).foregroundStyle(.secondary) }
                if highlighted { Text("Arrêt recherché").font(.caption.weight(.semibold)).foregroundStyle(color) }
            }.padding(.top, -2)
            Spacer()
        }
        .padding(.horizontal, highlighted ? 12 : 0)
        .padding(.top, highlighted ? 10 : 0)
        .background(highlighted ? color.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .frame(minHeight: 57, alignment: .top)
    }
}

private struct ThermometerVariant: Identifiable {
    let direction: T2CDirection
    let stops: [T2CStop]
    var id: String { direction.id }
}
private struct ThermometerDirection: Identifiable {
    let id: String
    let variants: [ThermometerVariant]
    var terminusNames: [String] { Array(Set(variants.map(\.direction.name))).sorted() }
    var label: String { id == "0" ? "Sens 1" : id == "1" ? "Sens 2" : "Parcours" }
}
private struct StopAccumulator {
    let name: String
    var positions: [Double] = []
    var isTerminus = false
}
private struct ThermometerStop: Identifiable {
    let id: String
    let name: String
    let position: Double
    let isTerminus: Bool
}

#Preview { ThermometerView() }
