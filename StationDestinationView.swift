import SwiftUI

struct StationDestinationView: View {
    let station: NearbyStation

    var body: some View {
        Group {
            if station.lines.count == 1, let line = station.lines.first {
                StationLineView(station: station, line: line)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(station.name)
                            .font(.largeTitle.bold())

                        Text("Quelle ligne prenez-vous ?")
                            .foregroundStyle(.secondary)

                        ForEach(station.lines) { line in
                            NavigationLink {
                                StationLineView(station: station, line: line)
                            } label: {
                                HStack(spacing: 18) {
                                    LineBadgeView(line: line, size: 62)

                                    Text(line.longName.isEmpty ? "Ligne \(line.shortName)" : line.longName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider()
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle("Choisir une ligne")
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StationLineView: View {
    let line: T2CLine
    @State private var station: NearbyStation
    @State private var choosingStop = false

    init(station: NearbyStation, line: T2CLine) {
        self.line = line
        _station = State(initialValue: station)
    }
    var body: some View {
        StationPassagesView(station: station, line: line, changeStop: { choosingStop = true })
            .id(station.id)
            .sheet(isPresented: $choosingStop) {
                NavigationStack {
                    LineStopsView(line: line, selectedStationID: station.id) { selected in
                        station = selected
                        choosingStop = false
                    }
                    .navigationTitle("Changer d’arrêt")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { choosingStop = false } } }
                }.presentationDragIndicator(.visible)
            }
    }
}

private struct StationPassagesView: View {
    let station: NearbyStation
    let line: T2CLine
    let changeStop: () -> Void
    @State private var trafficUnavailable = false

    @State private var departures: [T2CDeparture] = []
    @State private var messages: [T2CInfoMessage] = []
    @State private var alerts: [T2CAlert] = []
    @State private var directions: [StationDirection] = []
    @State private var loading = true
    @State private var error: String?
    @State private var updatedAt: Date?

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(PassengerAnnouncementSettings.enabledKey)
    private var passengerAnnouncementsEnabled = false

    @State private var hasAnnouncedThisVisit = false

    private func minutesString(for date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        let minutes = max(1, Int(ceil(seconds / 60)))
        return "\(minutes) min"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 18) {
                    LineBadgeView(line: line, size: 104)
                    Button(action: changeStop) {
                        VStack(spacing: 8) {
                            Text(station.name)
                                .font(.system(size: 28, weight: .bold)).multilineTextAlignment(.center)
                                .foregroundStyle(.primary)
                            Label("Changer d’arrêt", systemImage: "chevron.down")
                                .font(.subheadline.weight(.medium))
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity).padding(.top, 12)
                TrafficSummaryView(alerts: alerts, messages: messages, unavailable: trafficUnavailable, loading: loading)

                HStack {
                    Text("Prochains passages")
                        .font(.title2.bold())

                    if let updatedAt {
                        Text("· \(updatedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Actualisé à \(updatedAt.formatted(date: .omitted, time: .shortened))")
                    }

                    Spacer()

                    if loading {
                        ProgressView()
                    }
                }

                if let error {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("Réessayer") {
                        Task {
                            let announcementDirections = directions.isEmpty
                                ? await loadDirections()
                                : directions

                            await refresh(
                                directionsForAnnouncement: announcementDirections
                            )
                        }
                    }
                }

                ForEach(directionSections) { section in
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("DIRECTION").font(.caption2.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                            Label(section.title, systemImage: "arrow.up.right").font(.title3.weight(.semibold))
                        }

                        let matching = section.departures

                        if matching.isEmpty {
                            Text(
                                loading
                                ? "Chargement des passages…"
                                : "Aucun passage annoncé pour cette direction."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        } else {
                            ForEach(matching.prefix(6)) { departure in
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(
                                            departure.isCancelled
                                            ? "Annulé"
                                            : departure.isRealtime
                                            ? "Temps réel"
                                            : "Horaire théorique"
                                        )
                                        .font(.subheadline)
                                        .foregroundStyle(
                                            departure.isCancelled
                                            ? Color.red
                                            : .secondary
                                        )

                                        if let info = departure.info,
                                           !info.isEmpty {
                                            Text(info)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    if let timing = timingComparison(for: departure) {
                                        VStack(alignment: .trailing, spacing: 4) {
                                            HStack(spacing: 7) {
                                                Text(minutesString(for: timing.scheduledAt))
                                                    .foregroundStyle(.secondary)
                                                    .strikethrough(true, color: .secondary)

                                                Image(systemName: "arrow.right")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.secondary)

                                                Text(minutesString(for: timing.estimatedAt))
                                                    .foregroundStyle(timing.isDelayed ? Color.orange : Color.green)
                                            }
                                            .font(.title3.weight(.semibold))
                                            .monospacedDigit()

                                            Text(timing.label)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(timing.isDelayed ? Color.orange : Color.green)
                                        }
                                    } else {
                                        Text(minutesString(for: departure.dueAt))
                                            .font(.title2.weight(.semibold))
                                            .monospacedDigit()
                                            .strikethrough(departure.isCancelled)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        Divider()
                            .padding(.top, 8)
                    }
                }

                if !loading && directionSections.isEmpty && error == nil {
                    Text("Aucun passage annoncé à cet arrêt pour le moment.")
                        .foregroundStyle(.secondary)
                }


            }
            .padding(24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Ligne \(line.shortName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                return
            }

            // IMPORTANT : on conserve ici une copie locale des directions.
            // Cela évite de demander l'annonce sonore à SwiftUI avant que le
            // @State `directions` ait réellement provoqué son nouveau rendu.
            let loadedDirections = await loadDirections()

            await refresh(
                directionsForAnnouncement: loadedDirections
            )

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }

                await refresh(
                    directionsForAnnouncement: loadedDirections,
                    allowAnnouncement: false
                )
            }
        }
        .refreshable {
            hasAnnouncedThisVisit = false

            let announcementDirections = directions.isEmpty
                ? await loadDirections()
                : directions

            await refresh(
                directionsForAnnouncement: announcementDirections
            )
        }
        .onDisappear {
            PassengerAnnouncementService.shared.stop()
        }
    }

    // MARK: - Sections affichées

    private var directionSections: [PassageSection] {
        makeDirectionSections(
            directions: directions,
            departures: departures
        )
    }

    private func makeDirectionSections(
        directions sourceDirections: [StationDirection],
        departures sourceDepartures: [T2CDeparture]
    ) -> [PassageSection] {
        var sections = sourceDirections.map {
            PassageSection(
                id: $0.id,
                title: $0.names.first ?? "Direction non précisée",
                departures: []
            )
        }

        for departure in sourceDepartures {
            let destination = departure.destination ?? "Direction non précisée"

            let normalized = destination.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )

            let byName = sourceDirections.firstIndex { direction in
                direction.names.contains { name in
                    name.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: .current
                    ) == normalized
                }
            }

            let byPlatform = sourceDirections.firstIndex {
                $0.platformIDs.contains(departure.stopID)
            }

            if let index = byName ?? byPlatform {
                sections[index].departures.append(departure)
            } else if let index = sections.firstIndex(
                where: { $0.id == "destination:" + destination }
            ) {
                sections[index].departures.append(departure)
            } else {
                sections.append(
                    PassageSection(
                        id: "destination:" + destination,
                        title: destination,
                        departures: [departure]
                    )
                )
            }
        }

        for index in sections.indices {
            let announced = Set(
                sections[index].departures.compactMap(\.destination)
            )
            .sorted()

            if !announced.isEmpty {
                sections[index].title = announced.joined(separator: " / ")
            }
        }

        return sections
    }

    // MARK: - Chargement des directions

    @MainActor
    private func loadDirections() async -> [StationDirection] {
        do {
            let loaded = try await T2CService.shared.getDirections(
                for: line.routeID
            )

            var grouped: [String: StationDirection] = [:]
            let stationPlatformIDs = Set(station.platforms.map(\.id))

            for direction in loaded {
                if Task.isCancelled {
                    return []
                }

                let stops = try await T2CService.shared.getStops(
                    for: line.routeID,
                    direction: direction
                )

                let matchingPlatforms = Set(stops.map(\.stopID))
                    .intersection(stationPlatformIDs)

                guard !matchingPlatforms.isEmpty else {
                    continue
                }

                let key = direction.directionID.isEmpty
                    ? direction.name
                    : direction.directionID

                var group = grouped[key] ?? StationDirection(
                    id: key,
                    names: [],
                    platformIDs: []
                )

                if !group.names.contains(direction.name) {
                    group.names.append(direction.name)
                }

                group.platformIDs.formUnion(matchingPlatforms)
                grouped[key] = group
            }

            let finalDirections = grouped.values.sorted {
                $0.id < $1.id
            }

            directions = finalDirections

            return finalDirections

        } catch {
            print(
                "🔊 ClermonTard : impossible de charger les directions de la ligne \(line.shortName) : \(error.localizedDescription)"
            )

            return []
        }
    }

    // MARK: - Annonces voyageurs

    private func announcementItems(
        from sections: [PassageSection]
    ) -> [PassengerAnnouncementItem] {
        sections.compactMap { section in
            let directionName = section.title
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !directionName.isEmpty,
                  directionName != "Direction non précisée"
            else {
                return nil
            }

            let firstRealtime = section.departures
                .filter {
                    $0.isRealtime && !$0.isCancelled
                }
                .sorted {
                    $0.dueAt < $1.dueAt
                }
                .first

            return PassengerAnnouncementItem(
                directionName: firstRealtime?.destination ?? directionName,
                nextRealtimeDeparture: firstRealtime?.dueAt
            )
        }
    }

    private func announcePassengerInformation(
        directions announcementDirections: [StationDirection],
        departures announcementDepartures: [T2CDeparture]
    ) {
        let sections = makeDirectionSections(
            directions: announcementDirections,
            departures: announcementDepartures
        )

        let items = announcementItems(
            from: sections
        )

        guard !items.isEmpty else {
            // Très important : on ne marque PAS l'annonce comme effectuée.
            // Si SwiftUI / le GTFS n'était pas encore prêt, un prochain refresh
            // pourra retenter correctement.
            print(
                "🔊 ClermonTard : aucune direction prête pour l'annonce sur \(station.name) / ligne \(line.shortName)."
            )
            return
        }

        hasAnnouncedThisVisit = true

        print(
            "🔊 ClermonTard : annonce \(station.name) / ligne \(line.shortName) : \(items.map(\.directionName).joined(separator: " | "))"
        )

        PassengerAnnouncementService.shared.announce(items)
    }

    // MARK: - Rafraîchissement

    @MainActor
    private func refresh(
        directionsForAnnouncement announcementDirections: [StationDirection]? = nil,
        allowAnnouncement: Bool = true
    ) async {
        loading = true
        defer {
            loading = false
        }

        var results: [T2CTimetableResult] = []
        var failures = 0

        // Les identifiants de quai du GTFS et ceux de l'API QR peuvent être
        // momentanément désynchronisés. On interroge donc tous les quais de
        // l'arrêt ; getTimetable filtre ensuite strictement la ligne demandée.
        for platform in station.platforms {
            if Task.isCancelled {
                return
            }

            do {
                let result = try await T2CService.shared.getTimetable(
                    stopID: platform.id,
                    line: line,
                    limit: 20
                )

                results.append(result)
            } catch {
                failures += 1
            }
        }

        guard !Task.isCancelled else {
            return
        }

        if !results.isEmpty {
            // On crée d'abord une variable locale complète.
            // L'annonce utilise CETTE variable et non pas le @State juste modifié.
            let loadedDepartures = Array(
                Set(
                    results.flatMap {
                        $0.realtimeDepartures
                        + $0.theoreticalDepartures
                        + $0.cancelledDepartures
                    }
                )
            )
            .sorted {
                $0.dueAt < $1.dueAt
            }

            var uniqueMessages: [String: T2CInfoMessage] = [:]

            for message in results.flatMap(\.messages) {
                uniqueMessages[message.id] = message
            }

            let loadedMessages = uniqueMessages.values.sorted {
                $0.id < $1.id
            }

            // Mise à jour de l'interface.
            departures = loadedDepartures
            messages = loadedMessages
            updatedAt = .now

            if loadedDepartures.isEmpty {
                print(
                    "ClermonTard : aucun passage correspondant à la ligne \(line.shortName) "
                    + "pour les quais \(station.platforms.map(\.id).joined(separator: ", "))."
                )
            }

            // Mise à jour audio avec des snapshots locaux fiables.
            if allowAnnouncement,
               passengerAnnouncementsEnabled,
               !hasAnnouncedThisVisit {

                let directionsSnapshot = announcementDirections ?? directions

                announcePassengerInformation(
                    directions: directionsSnapshot,
                    departures: loadedDepartures
                )
            }
        }

        if failures > 0 {
            print("ClermonTard : \(failures) quai(s) sans réponse pour \(station.name), ligne \(line.shortName).")
        }
        error = results.isEmpty && failures > 0
            ? "Les horaires sont indisponibles. Vérifiez votre connexion puis réessayez."
            : nil

        do {
            alerts = try await T2CService.shared.getAlerts(
                for: line.routeID
            )
            trafficUnavailable = false
        } catch {
            trafficUnavailable = true
            // On garde les anciennes alertes si l'API ne répond pas.
        }
    }

    private func timingComparison(for departure: T2CDeparture) -> PassageTimingComparison? {
        guard !departure.isCancelled,
              let scheduledAt = departure.scheduledAt,
              let estimatedAt = departure.estimatedAt else { return nil }

        let difference = estimatedAt.timeIntervalSince(scheduledAt)
        guard abs(difference) >= 120 else { return nil }
        let minutes = max(Int((abs(difference) / 60).rounded()), 1)
        let delayed = difference > 0
        return PassageTimingComparison(
            scheduledAt: scheduledAt,
            estimatedAt: estimatedAt,
            isDelayed: delayed,
            label: delayed ? "+\(minutes) min de retard" : "\(minutes) min d’avance"
        )
    }
}

private struct StationDirection {
    let id: String
    var names: [String]
    var platformIDs: Set<String>
}

private struct PassageSection: Identifiable {
    let id: String
    var title: String
    var departures: [T2CDeparture]
}

private struct PassageTimingComparison {
    let scheduledAt: Date
    let estimatedAt: Date
    let isDelayed: Bool
    let label: String
}
