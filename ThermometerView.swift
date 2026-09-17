import SwiftUI
import MapKit

struct ThermometerView: View {
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    @State private var lines: [T2CLine] = []
    @State private var stations: [NearbyStation] = []
    @State private var query = ""
    @State private var indexedQuery = ""
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
        guard !indexedQuery.isEmpty else { return [] }
        return sortedLines.filter {
            $0.shortName.localizedStandardContains(indexedQuery) || $0.longName.localizedStandardContains(indexedQuery)
        }
    }

    private var matchingStations: [NearbyStation] {
        guard !indexedQuery.isEmpty else { return [] }
        // Une liste bornée évite de reconstruire des centaines de résultats
        // pendant que le clavier livre encore ses candidats.
        return Array(stations.lazy.filter {
            StationSearch.matches($0.name, query: indexedQuery)
        }.prefix(30))
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
            .navigationTitle("Lignes")
            .background(Color(uiColor: .systemBackground))
            .scrollDismissesKeyboard(.interactively)
            .task { if lines.isEmpty { await load() } }
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                indexedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            }
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
    @State private var highlightPulse = false
    @State private var hasCenteredInitialHighlight = false
    @State private var mapShapes: [T2CLineShape] = []
    @State private var mapStops: [LineMapStop] = []
    @State private var mapLoading = false
    @State private var mapError: String?

    private let planID = "__plan__"
    private var offersPlan: Bool {
        ["A", "B", "C", "E1", "E2", "E3", "E4", "E5", "E6", "E7"]
            .contains(line.shortName.uppercased().replacingOccurrences(of: " ", with: ""))
    }

    private var selectedGroup: ThermometerDirection? {
        groups.first { $0.id == selectedID } ?? groups.first
    }

    var body: some View {
        ScrollViewReader { proxy in
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
                        Button("Réessayer") { Task { await load(); await centerHighlightedStop(using: proxy) } }
                    }

                    if groups.count > 1 || offersPlan {
                        Picker("Affichage", selection: $selectedID) {
                            ForEach(groups) { group in
                                Text(group.label).tag(group.id)
                            }
                            if offersPlan {
                                Text("Plans").tag(planID)
                            }
                        }.pickerStyle(.segmented)
                    }

                    if selectedID == planID {
                        linePlan
                            .frame(maxWidth: .infinity, minHeight: 500)
                    } else if let group = selectedGroup {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("TERMINUS POSSIBLES")
                                .font(.caption2.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
                            Text(group.terminusNames.joined(separator: " · "))
                                .font(.headline)
                        }

                        let stops = displayedStops(group)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                                let highlighted = highlightedStopName.map {
                                    stop.name.localizedStandardContains($0)
                                } ?? false
                                ThermometerStopRow(
                                    stop: stop,
                                    color: Color(hex: line.colorHex),
                                    drawsLine: index < stops.count - 1,
                                    highlighted: highlighted,
                                    pulsing: highlighted && highlightPulse
                                )
                                .id(stop.id)
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
            .task {
                await load()
                await centerHighlightedStop(using: proxy)
                hasCenteredInitialHighlight = true
            }
            .onChange(of: selectedID) { _, _ in
                guard hasCenteredInitialHighlight else { return }
                if selectedID == planID {
                    Task { await loadPlanIfNeeded() }
                } else {
                    Task { await centerHighlightedStop(using: proxy) }
                }
            }
        }
    }

    @ViewBuilder private var linePlan: some View {
        if mapLoading {
            VStack(spacing: 14) {
                ProgressView()
                Text("Chargement du tracé officiel T2C…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        } else if let mapError {
            ContentUnavailableView {
                Label("Plan indisponible", systemImage: "map")
            } description: {
                Text(mapError)
            } actions: {
                Button("Réessayer") { Task { await loadPlanIfNeeded(force: true) } }
            }
        } else if !mapShapes.isEmpty {
            LineRouteMap(line: line, shapes: mapShapes, stops: mapStops)
                .frame(height: 500)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .topLeading) {
                    Label("Tracé officiel GTFS", systemImage: "map.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                }
        }
    }

    @MainActor private func loadPlanIfNeeded(force: Bool = false) async {
        guard offersPlan, force || mapShapes.isEmpty else { return }
        mapLoading = true
        mapError = nil
        defer { mapLoading = false }
        do {
            async let loadedShapes = T2CService.shared.getLineShapes(for: line.routeID)
            async let loadedStations = T2CService.shared.getStations()
            let (shapes, stations) = try await (loadedShapes, loadedStations)
            guard !shapes.isEmpty else {
                mapError = "T2C ne fournit actuellement aucun tracé pour cette ligne."
                return
            }
            mapShapes = shapes
            // Index spatial grossier : évite des millions de créations de
            // CLLocation et de calculs de distance sur le thread principal.
            let shapeCells = Set(shapes.flatMap(\.points).map {
                "\(Int($0.latitude * 2_000))|\(Int($0.longitude * 2_000))"
            })
            mapStops = stations.compactMap { station in
                guard station.lines.contains(where: { $0.routeID == line.routeID }) else { return nil }
                let coordinates = station.platforms.compactMap { platform -> T2CShapePoint? in
                    guard platform.routeIDs.contains(line.routeID),
                          let latitude = platform.latitude,
                          let longitude = platform.longitude else { return nil }
                    return T2CShapePoint(latitude: latitude, longitude: longitude)
                }
                guard !coordinates.isEmpty else { return nil }
                let latitude = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
                let longitude = coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
                // Les stations du catalogue peuvent appartenir à une variante
                // sans shape publiée. Ne pas les dessiner « dans le vide ».
                let latitudeCell = Int(latitude * 2_000)
                let longitudeCell = Int(longitude * 2_000)
                let touchesShape = (-1...1).contains { latitudeOffset in
                    (-1...1).contains { longitudeOffset in
                        shapeCells.contains("\(latitudeCell + latitudeOffset)|\(longitudeCell + longitudeOffset)")
                    }
                }
                guard touchesShape else { return nil }
                return LineMapStop(
                    id: station.id,
                    name: station.name,
                    latitude: latitude,
                    longitude: longitude
                )
            }
        } catch is CancellationError {
            return
        } catch {
            mapError = "Impossible de charger le plan. Vérifiez votre connexion puis réessayez."
        }
    }

    @MainActor private func centerHighlightedStop(using proxy: ScrollViewProxy) async {
        guard let highlightedStopName,
              let group = selectedGroup,
              let target = displayedStops(group).first(where: {
                  $0.name.localizedStandardContains(highlightedStopName)
              }) else { return }
        await Task.yield()
        withAnimation(.easeInOut(duration: 0.45)) {
            proxy.scrollTo(target.id, anchor: .center)
        }
        try? await Task.sleep(for: .milliseconds(450))
        highlightPulse = false
        withAnimation(.easeInOut(duration: 0.32)) {
            highlightPulse = true
        }
        try? await Task.sleep(for: .milliseconds(320))
        withAnimation(.easeInOut(duration: 0.32)) {
            highlightPulse = false
        }
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

    private func displayedStops(_ group: ThermometerDirection) -> [ThermometerStop] {
        let matchingVariants = highlightedStopName.map { searchedName in
            group.variants.filter { variant in
                variant.stops.contains { $0.name.localizedStandardContains(searchedName) }
            }
        } ?? []
        let candidates = matchingVariants.isEmpty ? group.variants : matchingVariants
        guard let variant = candidates.max(by: { $0.stops.count < $1.stops.count }) else { return [] }

        let passengerIndexes = variant.stops.indices.filter { !isTechnicalStop(variant.stops[$0].name) }
        let firstPassengerIndex = passengerIndexes.first
        let lastPassengerIndex = passengerIndexes.last

        return variant.stops.enumerated().map { index, stop in
            let technical = isTechnicalStop(stop.name)
            return ThermometerStop(
                id: "\(index)|\(stop.stopID)",
                name: stop.name,
                position: Double(index),
                isTerminus: !technical && (index == firstPassengerIndex || index == lastPassengerIndex),
                isTechnical: technical
            )
        }
    }

    private func isTechnicalStop(_ name: String) -> Bool {
        let normalizedLine = line.shortName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedLine == "B" || normalizedLine == "C" else { return false }
        return name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .contains("parking")
    }
}

private struct ThermometerStopRow: View {
    let stop: ThermometerStop
    let color: Color
    let drawsLine: Bool
    let highlighted: Bool
    let pulsing: Bool
    var body: some View {
        let stopColor = stop.isTechnical ? Color.secondary : color
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                Circle()
                    .fill(stop.isTerminus ? stopColor : Color(uiColor: .systemBackground))
                    .overlay { Circle().stroke(stopColor, lineWidth: 3) }
                    .frame(width: 15, height: 15)
                if drawsLine { Rectangle().fill(stopColor.opacity(0.55)).frame(width: 3, height: 42) }
            }.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(stop.name)
                    .font(stop.isTerminus ? .body.bold() : .body)
                    .foregroundStyle(stop.isTechnical ? .secondary : .primary)
                if stop.isTerminus { Text("Terminus").font(.caption).foregroundStyle(.secondary) }
                if highlighted { Text("Arrêt recherché").font(.caption.weight(.semibold)).foregroundStyle(color) }
            }
            .padding(.horizontal, highlighted ? 12 : 0)
            .padding(.vertical, highlighted ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                highlighted ? color.opacity(pulsing ? 0.24 : 0.09) : .clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .padding(.top, highlighted ? -8 : -2)
        }
        .animation(.easeInOut(duration: 0.28), value: pulsing)
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
private struct ThermometerStop: Identifiable {
    let id: String
    let name: String
    let position: Double
    let isTerminus: Bool
    let isTechnical: Bool
}

private struct LineMapStop: Identifiable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
}

private struct LineRouteMap: View {
    let line: T2CLine
    let shapes: [T2CLineShape]
    let stops: [LineMapStop]
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(shapes) { shape in
                MapPolyline(coordinates: shape.points.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(
                    Color(hex: line.colorHex),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                )
            }

            ForEach(stops) { stop in
                Annotation(stop.name, coordinate: CLLocationCoordinate2D(
                    latitude: stop.latitude,
                    longitude: stop.longitude
                )) {
                    Circle()
                        .fill(Color(uiColor: .systemBackground))
                        .stroke(Color(hex: line.colorHex), lineWidth: 3)
                        .frame(width: 12, height: 12)
                        .accessibilityLabel(stop.name)
                }
            }

            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {
            MapCompass()
            MapScaleView()
            MapUserLocationButton()
        }
    }
}

#Preview { ThermometerView() }
