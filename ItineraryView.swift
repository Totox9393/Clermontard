import SwiftUI
import CoreLocation
import Combine

struct ItineraryView: View {
    @State private var stations: [NearbyStation] = []
    @State private var origin: NearbyStation?
    @State private var destination: NearbyStation?
    @State private var departureDate = Date()
    @State private var pickerRole: StopPickerRole?
    @State private var journeys: [T2CJourney] = []
    @State private var loadingStations = true
    @State private var calculating = false
    @State private var refreshingJourneys = false
    @State private var visibleJourneyCount = 3
    @State private var allowWalking = true
    @State private var groqRecommendedJourneyID: String?
    @State private var error: String?
    @StateObject private var locationProvider = JourneyLocationProvider()
    @Environment(\.scenePhase) private var scenePhase

    private var availableJourneys: [T2CJourney] {
        journeys.filter { journey in
            journey.directWalk != nil ? journey.arrivalAt >= Date() : journey.departureAt >= Date()
        }
    }

    private var visibleJourneys: [T2CJourney] {
        Array(availableJourneys.prefix(visibleJourneyCount))
    }

    private var recommendedJourneyID: String? {
        if let groqRecommendedJourneyID,
           availableJourneys.contains(where: { $0.id == groqRecommendedJourneyID }) {
            return groqRecommendedJourneyID
        }
        return availableJourneys.min { journeyScore($0) < journeyScore($1) }?.id
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(spacing: 0) {
                        stopButton(role: .origin, station: origin)
                        HStack(spacing: 14) {
                            VStack(spacing: 0) {
                                Circle().fill(Color(hex: "C60024")).frame(width: 10, height: 10)
                                Rectangle().fill(Color(hex: "C60024").opacity(0.35)).frame(width: 2, height: 34)
                                Circle().stroke(Color(hex: "C60024"), lineWidth: 3).frame(width: 10, height: 10)
                            }
                            Spacer()
                            Button {
                                (origin, destination) = (destination, origin)
                                journeys = []
                            } label: {
                                Label("Inverser", systemImage: "arrow.up.arrow.down")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .padding(.horizontal, 18)
                        stopButton(role: .destination, station: destination)
                    }

                    DatePicker(
                        "Départ",
                        selection: $departureDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)

                    Toggle(isOn: $allowWalking) {
                        Label("Je peux marcher un peu si nécessaire", systemImage: "figure.walk")
                            .font(.subheadline)
                    }
                    .tint(Color(hex: "C60024"))
                    .onChange(of: allowWalking) { _, _ in journeys = []; groqRecommendedJourneyID = nil }

                    Button { Task { await calculate() } } label: {
                        HStack {
                            if calculating { ProgressView().tint(.white) }
                            Text(calculating ? "Calcul en cours…" : "Rechercher un itinéraire")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(18)
                        .background(Color(hex: "C60024"), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(origin == nil || destination == nil || calculating)
                    .opacity(origin == nil || destination == nil ? 0.45 : 1)

                    if loadingStations { ProgressView("Chargement des arrêts…") }
                    if let error { Text(error).font(.subheadline).foregroundStyle(.secondary) }

                    if !journeys.isEmpty {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Itinéraires proposés").font(.title2.bold())
                            ForEach(visibleJourneys) { journey in
                                NavigationLink {
                                    JourneyTrackingView(journey: journey)
                                } label: {
                                    JourneyCard(journey: journey, recommended: journey.id == recommendedJourneyID)
                                }
                                .buttonStyle(.plain)
                            }
                            if visibleJourneyCount < availableJourneys.count {
                                Button {
                                    visibleJourneyCount = min(visibleJourneyCount + 3, availableJourneys.count)
                                } label: {
                                    Label("Charger d’autres itinéraires", systemImage: "chevron.down")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                }
                                .buttonStyle(.bordered)
                            }
                            Text("Les départs marqués « Temps réel » viennent de T2C. Les temps entre les arrêts restent estimés.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Itinéraire")
            .background(Color(uiColor: .systemBackground))
            .task {
                locationProvider.locate()
                await loadStations()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, !journeys.isEmpty else { return }
                Task { await refreshDisplayedJourneys() }
            }
            .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
                journeys.removeAll { journey in
                    journey.directWalk != nil ? journey.arrivalAt < Date() : journey.departureAt < Date()
                }
                visibleJourneyCount = min(visibleJourneyCount, max(journeys.count, 3))
            }
            .sheet(item: $pickerRole) { role in
                StationPickerSheet(
                    stations: stations,
                    title: role.title,
                    role: role,
                    excludedStationID: role == .destination ? origin?.id : destination?.id,
                    location: locationProvider.location
                ) { station in
                    if role == .origin { origin = station } else { destination = station }
                    journeys = []
                    pickerRole = nil
                }
            }
        }
    }

    private func stopButton(role: StopPickerRole, station: NearbyStation?) -> some View {
        Button { pickerRole = role } label: {
            HStack(spacing: 14) {
                Image(systemName: role == .origin ? "location.fill" : "flag.checkered")
                    .frame(width: 24)
                    .foregroundStyle(Color(hex: "C60024"))
                VStack(alignment: .leading, spacing: 4) {
                    Text(role == .origin ? "DÉPART" : "ARRIVÉE")
                        .font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Text(station?.name ?? "Choisir un arrêt")
                        .font(.headline).foregroundStyle(station == nil ? .secondary : .primary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor private func loadStations() async {
        guard stations.isEmpty else { return }
        loadingStations = true
        defer { loadingStations = false }
        do { stations = try await T2CService.shared.getStations() }
        catch { self.error = "Impossible de charger les arrêts T2C." }
    }

    @MainActor private func calculate() async {
        guard let origin, let destination else { return }
        guard origin.id != destination.id else {
            error = "Choisissez deux arrêts différents."
            return
        }
        calculating = true; error = nil; journeys = []
        visibleJourneyCount = 3
        defer { calculating = false }
        do {
            journeys = try await T2CService.shared.calculateJourneys(
                from: origin,
                to: destination,
                departureDate: max(departureDate, .now),
                limit: 30,
                allowWalking: allowWalking
            )
            groqRecommendedJourneyID = await GroqAPI.shared.recommendJourney(
                from: journeys,
                requestedDeparture: max(departureDate, .now)
            )
            if journeys.isEmpty { error = "Aucun parcours simple trouvé entre ces deux arrêts." }
        } catch { self.error = "Le calcul de l’itinéraire a échoué. Réessayez dans un instant." }
    }

    @MainActor private func refreshDisplayedJourneys() async {
        guard !refreshingJourneys, let origin, let destination else { return }
        refreshingJourneys = true
        defer { refreshingJourneys = false }
        do {
            let refreshed = try await T2CService.shared.calculateJourneys(
                from: origin,
                to: destination,
                departureDate: max(departureDate, .now),
                limit: 30,
                allowWalking: allowWalking
            )
            journeys = refreshed
            groqRecommendedJourneyID = await GroqAPI.shared.recommendJourney(
                from: refreshed,
                requestedDeparture: max(departureDate, .now)
            )
            visibleJourneyCount = min(max(visibleJourneyCount, 3), max(refreshed.count, 3))
            error = refreshed.isEmpty ? "Aucun autre départ disponible pour le moment." : nil
        } catch {
            journeys.removeAll { $0.departureAt < Date() }
        }
    }

    private func journeyScore(_ journey: T2CJourney) -> TimeInterval {
        // L'arrivée compte le plus; changements, marche et correspondances serrées
        // départagent les parcours proches sans bouleverser l'ordre chronologique.
        let riskyTransfers = journey.legs.compactMap(\.transferBuffer).filter { $0 < 300 }.count
        return journey.arrivalAt.timeIntervalSince1970
            + Double(journey.transferCount) * 240
            + journey.walkingDuration * 0.35
            + Double(riskyTransfers) * 300
    }
}

private enum StopPickerRole: String, Identifiable {
    case origin, destination
    var id: String { rawValue }
    var title: String { self == .origin ? "Arrêt de départ" : "Arrêt d’arrivée" }
}

private struct StationPickerSheet: View {
    let stations: [NearbyStation]
    let title: String
    let role: StopPickerRole
    let excludedStationID: String?
    let location: CLLocation?
    let onSelect: (NearbyStation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var indexedQuery = ""

    private var results: [NearbyStation] {
        let available = stations.filter { $0.id != excludedStationID }
        if !indexedQuery.isEmpty {
            return Array(available.filter {
                StationSearch.matches($0.name, query: indexedQuery)
            }.prefix(30))
        }
        guard let location else { return Array(available.prefix(10)) }
        return Array(available.sorted {
            distance(from: location, to: $0) < distance(from: location, to: $1)
        }.prefix(10))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                SearchField(placeholder: "Rechercher un arrêt", text: $query)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                if indexedQuery.isEmpty {
                    Text(role == .origin && location != nil ? "LES 10 PLUS PROCHES" : "SUGGESTIONS")
                        .font(.caption2.weight(.semibold)).tracking(1.3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                }

                List(results) { station in
                    Button { onSelect(station) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: station.lines.contains(where: \.isTram) ? "tram.fill" : "bus.fill")
                                .foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(station.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 5) {
                                        ForEach(station.lines) { line in
                                            LineBadgeView(line: line, size: 27)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                indexedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } } }
        }
    }

    private func distance(from location: CLLocation, to station: NearbyStation) -> CLLocationDistance {
        station.platforms.compactMap { platform in
            guard let latitude = platform.latitude, let longitude = platform.longitude else { return nil }
            return location.distance(from: CLLocation(latitude: latitude, longitude: longitude))
        }.min() ?? .greatestFiniteMagnitude
    }
}

private struct JourneyCard: View {
    let journey: T2CJourney
    let recommended: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(journey.departureAt.formatted(date: .omitted, time: .shortened)) → \(journey.arrivalAt.formatted(date: .omitted, time: .shortened))")
                        .font(.title3.bold()).monospacedDigit()
                    Text("Environ \(max(Int(journey.duration / 60), 1)) min · \(journey.transferCount == 0 ? "Direct" : "\(journey.transferCount) changement\(journey.transferCount > 1 ? "s" : "")")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if recommended {
                    Text("ITINÉRAIRE CONSEILLÉ")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }

            if let walk = journey.directWalk {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Marcher environ \(max(Int(ceil(walk.duration / 60)), 1)) min sur \(max(Int(walk.distance.rounded() / 10) * 10, 10)) m vers \(walk.destination.name)")
                            .font(.headline)
                    }
                } icon: {
                    Image(systemName: "figure.walk.circle.fill").font(.title)
                        .foregroundStyle(.primary)
                }
            }

            ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                if let walk = leg.walkBefore {
                    Label {
                        Text("Marcher environ \(max(Int(ceil(walk.duration / 60)), 1)) min sur \(max(Int(walk.distance.rounded() / 10) * 10, 10)) m vers \(walk.destination.name)")
                    } icon: {
                        Image(systemName: "figure.walk")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                }
                if index > 0, let buffer = leg.transferBuffer {
                    HStack(spacing: 8) {
                        LineBadgeView(line: journey.legs[index - 1].line, size: 28)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        LineBadgeView(line: leg.line, size: 28)
                        Label(
                            "Attente · \(max(Int(buffer / 60), 0)) min",
                            systemImage: buffer < 300 ? "exclamationmark.circle.fill" : "clock"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(buffer < 300 ? .orange : .secondary)
                    }
                }
                HStack(alignment: .top, spacing: 15) {
                    LineBadgeView(line: leg.line, size: 50)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(leg.departureAt.formatted(date: .omitted, time: .shortened)).font(.headline).monospacedDigit()
                            Text(leg.origin.name).font(.headline)
                        }
                        Label("Direction \(leg.direction)", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.medium))
                        Text("\(leg.stopCount) arrêt\(leg.stopCount > 1 ? "s" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(leg.arrivalAt.formatted(date: .omitted, time: .shortened)).font(.subheadline.bold()).monospacedDigit()
                            Text("Descendre à \(leg.destination.name)").font(.subheadline)
                        }
                        Text(leg.isRealtime ? "Temps réel au départ" : "Horaire théorique estimé")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(leg.isRealtime ? .green : .secondary)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

@MainActor
private final class JourneyLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var location: CLLocation?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func locate() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

#Preview { ItineraryView() }
