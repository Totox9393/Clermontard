import SwiftUI
import CoreLocation
import Combine
import UserNotifications
import UIKit

struct JourneyTrackingView: View {
    let journey: T2CJourney
    @StateObject private var tracker: JourneyTracker
    @State private var currentDate = Date()

    private var isExpired: Bool {
        !tracker.isTracking && (journey.directWalk != nil ? journey.arrivalAt < currentDate : journey.departureAt < currentDate)
    }

    init(journey: T2CJourney) {
        self.journey = journey
        _tracker = StateObject(wrappedValue: JourneyTracker(journey: journey))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isExpired {
                    ContentUnavailableView(
                        "Itinéraire expiré",
                        systemImage: "clock.badge.xmark",
                        description: Text("Ce véhicule est déjà passé. Revenez aux résultats pour choisir le prochain départ.")
                    )
                    .padding(.top, 80)
                } else if tracker.isTracking {
                    trackingHeader
                    if let walk = journey.directWalk {
                        Label("Marcher environ \(max(Int(ceil(walk.duration / 60)), 1)) min sur \(max(Int(walk.distance.rounded() / 10) * 10, 10)) m vers \(walk.destination.name)", systemImage: "figure.walk")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                    } else if let leg = tracker.currentLeg {
                        JourneyStopThermometer(
                            leg: leg,
                            currentStopIndex: tracker.currentStopIndex,
                            tracking: true
                        )
                    }
                } else {
                    overview
                }
            }
            .padding(24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(tracker.isTracking ? "Suivi en cours" : "Détail du trajet")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom) {
            if !tracker.isTracking && !isExpired {
                Button { tracker.start() } label: {
                    Label("Démarrer le suivi", systemImage: "location.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(17)
                        .foregroundStyle(.white)
                        .background(Color(hex: "C60024"), in: Capsule())
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .toolbar {
            if tracker.isTracking {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Arrêter") { tracker.stop() }
                }
            }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { date in
            currentDate = date
            tracker.checkExpiration(at: date)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(journey.departureAt.formatted(date: .omitted, time: .shortened)) → \(journey.arrivalAt.formatted(date: .omitted, time: .shortened))")
                        .font(.title2.bold()).monospacedDigit()
                    Text("\(journey.transferCount == 0 ? "Trajet direct" : "\(journey.transferCount) changement\(journey.transferCount > 1 ? "s" : "")")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    ForEach(journey.legs) { LineBadgeView(line: $0.line, size: 32) }
                    if journey.directWalk != nil { Image(systemName: "figure.walk.circle.fill").font(.title) }
                }
            }

            if let walk = journey.directWalk {
                Label("Marcher environ \(max(Int(ceil(walk.duration / 60)), 1)) min sur \(max(Int(walk.distance.rounded() / 10) * 10, 10)) m vers \(walk.destination.name)", systemImage: "figure.walk")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                if let walk = leg.walkBefore {
                    Label(
                        "Marcher environ \(max(Int(ceil(walk.duration / 60)), 1)) min sur \(max(Int(walk.distance.rounded() / 10) * 10, 10)) m vers \(walk.destination.name)",
                        systemImage: "figure.walk"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                }
                if index > 0, let wait = leg.transferBuffer {
                    HStack(spacing: 8) {
                        LineBadgeView(line: journey.legs[index - 1].line, size: 28)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        LineBadgeView(line: leg.line, size: 28)
                        Text("Attente estimée : \(max(Int(wait / 60), 0)) min")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                JourneyStopThermometer(leg: leg, currentStopIndex: nil, tracking: false)
            }
        }
    }

    private var trackingHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let leg = tracker.currentLeg { LineBadgeView(line: leg.line, size: 58) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(tracker.statusTitle).font(.title2.bold())
                    Text(tracker.statusDetail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let accuracy = tracker.accuracy {
                Label("Position GPS à ±\(Int(accuracy.rounded())) m", systemImage: "location.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct JourneyStopThermometer: View {
    let leg: T2CJourneyLeg
    let currentStopIndex: Int?
    let tracking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                LineBadgeView(line: leg.line, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Direction \(leg.direction)").font(.headline)
                    Text("Descendre à \(leg.destination.name)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(leg.stations.enumerated()), id: \.element.id) { index, station in
                    let reached = currentStopIndex.map { index <= $0 } ?? false
                    HStack(alignment: .top, spacing: 15) {
                        VStack(spacing: 0) {
                            Circle()
                                .fill(reached ? Color(hex: leg.line.colorHex) : Color(uiColor: .systemBackground))
                                .overlay { Circle().stroke(Color(hex: leg.line.colorHex), lineWidth: 3) }
                                .frame(width: 15, height: 15)
                                .overlay {
                                    if currentStopIndex == index {
                                        Circle().stroke(Color.primary, lineWidth: 2).frame(width: 25, height: 25)
                                    }
                                }
                            if index < leg.stations.count - 1 {
                                Rectangle()
                                    .fill(Color(hex: leg.line.colorHex).opacity(reached ? 0.9 : 0.35))
                                    .frame(width: 3, height: 38)
                            }
                        }
                        .frame(width: 25)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.name)
                                .font(index == 0 || index == leg.stations.count - 1 ? .body.bold() : .body)
                            if tracking && currentStopIndex == index {
                                Text("Votre position").font(.caption.bold()).foregroundStyle(Color(hex: leg.line.colorHex))
                            }
                        }
                        .padding(.top, -3)
                        Spacer()
                    }
                    .frame(minHeight: index < leg.stations.count - 1 ? 53 : 30, alignment: .top)
                }
            }
        }
    }
}

@MainActor
final class JourneyTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Phase { case waiting, onBoard, changing, completed }

    @Published private(set) var journey: T2CJourney
    @Published private(set) var isTracking = false
    @Published private(set) var currentLegIndex = 0
    @Published private(set) var currentStopIndex = 0
    @Published private(set) var phase: Phase = .waiting
    @Published private(set) var accuracy: CLLocationAccuracy?
    @Published private(set) var walkingDistanceRemaining: CLLocationDistance?

    private let manager = CLLocationManager()
    private var visitedOrigin = false
    private var sentNotifications: Set<String> = []
    private var recalculating = false
    private var lastOnRouteAt: Date?
    private let liveActivity = JourneyLiveActivityController()

    init(journey: T2CJourney) {
        self.journey = journey
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 6
        manager.pausesLocationUpdatesAutomatically = false
    }

    var currentLeg: T2CJourneyLeg? {
        journey.legs.indices.contains(currentLegIndex) ? journey.legs[currentLegIndex] : nil
    }

    var statusTitle: String {
        if let walk = journey.directWalk { return "Marchez vers \(walk.destination.name)" }
        guard let leg = currentLeg else { return phase == .completed ? "Vous êtes arrivé" : "Suivi terminé" }
        if phase == .waiting, leg.walkBefore != nil, walkingDistanceRemaining.map({ $0 > 120 }) != false {
            return "Marchez vers \(leg.origin.name)"
        }
        switch phase {
        case .waiting: return "Attendez la ligne \(leg.line.shortName)"
        case .onBoard: return "À bord de la ligne \(leg.line.shortName)"
        case .changing: return "Changement en cours"
        case .completed: return "Vous êtes arrivé"
        }
    }

    var statusDetail: String {
        if journey.directWalk != nil, let metres = walkingDistanceRemaining {
            return metres <= 40 ? "Vous êtes arrivé" : "Encore environ \(max(Int(metres.rounded() / 10) * 10, 10)) m"
        }
        guard let leg = currentLeg else { return journey.legs.last?.destination.name ?? "Destination atteinte" }
        if phase == .waiting, leg.walkBefore != nil, let metres = walkingDistanceRemaining, metres > 120 {
            return "Encore environ \(max(Int(metres.rounded() / 10) * 10, 10)) m avant la ligne \(leg.line.shortName)"
        }
        let remaining = max(leg.stations.count - currentStopIndex - 1, 0)
        if phase == .waiting {
            let minutes = max(Int(ceil(leg.departureAt.timeIntervalSinceNow / 60)), 0)
            return "Direction \(leg.direction) · départ dans \(minutes) min"
        }
        return remaining == 0 ? "Descendez à \(leg.destination.name)" : "\(remaining) arrêt\(remaining > 1 ? "s" : "") avant \(leg.destination.name)"
    }

    func start() {
        guard !isTracking else { return }
        isTracking = true
        updateLiveActivity(startIfNeeded: true)
        Task { try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        configureAuthorization()
    }

    func stop() {
        manager.stopUpdatingLocation()
        isTracking = false
        liveActivity.cancel()
    }

    private func configureAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            beginUpdates()
        case .authorizedAlways:
            beginUpdates()
        default:
            beginUpdates()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            beginUpdates()
        }
    }

    private func beginUpdates() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isTracking, let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        checkExpiration()
        guard isTracking else { return }
        accuracy = location.horizontalAccuracy
        process(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func checkExpiration(at date: Date = .now) {
        guard isTracking, phase != .completed else { return }

        // Si le GPS confirme encore que l'utilisateur avance sur la ligne, on
        // tolère un retard réel. Sinon le suivi expire rapidement après l'heure
        // prévue et ne reste pas bloqué dans la Dynamic Island.
        let recentlyOnRoute = lastOnRouteAt.map { date.timeIntervalSince($0) < 90 } ?? false
        let grace: TimeInterval = phase == .onBoard && recentlyOnRoute ? 15 * 60 : 60
        guard date > journey.arrivalAt.addingTimeInterval(grace) else { return }
        manager.stopUpdatingLocation()
        isTracking = false
        liveActivity.cancel()
    }

    private func process(_ location: CLLocation) {
        if let walk = journey.directWalk {
            let metres = distance(from: location, to: walk.destination)
            walkingDistanceRemaining = metres
            if metres <= 40 {
                phase = .completed
                notify(title: "Vous êtes arrivé à \(walk.destination.name)", body: "Trajet à pied terminé.", id: "walking-arrival")
                manager.stopUpdatingLocation()
                isTracking = false
            }
            return
        }
        guard let leg = currentLeg, !leg.stations.isEmpty else { return }
        if phase == .waiting, leg.walkBefore != nil {
            let metres = distance(from: location, to: leg.origin)
            walkingDistanceRemaining = metres
            if metres > 120 {
                updateLiveActivity()
                return
            }
            walkingDistanceRemaining = nil
        }
        let distances = leg.stations.map { distance(from: location, to: $0) }
        guard let candidate = distances.enumerated().min(by: { $0.element < $1.element }), candidate.element < 180 else {
            checkMissedConnection()
            return
        }
        lastOnRouteAt = .now

        if distances[0] < 140 { visitedOrigin = true }
        if candidate.offset >= currentStopIndex { currentStopIndex = candidate.offset }

        // Être rapide ne suffit pas : le passage à bord n'est validé qu'après
        // l'origine, dans l'ordre des arrêts et autour de l'heure de départ.
        if phase == .waiting,
           visitedOrigin,
           currentStopIndex > 0,
           Date() >= leg.departureAt.addingTimeInterval(-120) {
            phase = .onBoard
        }

        let remaining = leg.stations.count - currentStopIndex - 1
        if phase == .onBoard && remaining == 2 {
            notifyApproach(stops: 2, leg: leg)
        } else if phase == .onBoard && remaining == 1 {
            notifyApproach(stops: 1, leg: leg)
        }

        if currentStopIndex == leg.stations.count - 1 {
            arriveAtEndOfLeg()
        } else {
            updateLiveActivity()
            checkMissedConnection()
        }
    }

    private func arriveAtEndOfLeg() {
        guard currentLegIndex < journey.legs.count - 1 else {
            phase = .completed
            let destination = journey.legs.last?.destination.name ?? "destination"
            notify(
                title: "Vous êtes arrivé à \(destination)",
                body: "Trajet terminé avec la ligne \(currentLeg?.line.shortName ?? "T2C").",
                id: "arrival",
                line: currentLeg?.line
            )
            liveActivity.end(finalStop: destination)
            manager.stopUpdatingLocation()
            return
        }
        currentLegIndex += 1
        currentStopIndex = 0
        walkingDistanceRemaining = nil
        visitedOrigin = true
        phase = .waiting
        guard let next = currentLeg else { return }
        let minutes = max(Int(ceil(next.departureAt.timeIntervalSinceNow / 60)), 0)
        notify(
            title: "Changement à \(next.origin.name)",
            body: "Ligne \(next.line.shortName), direction \(next.direction), dans environ \(minutes) min.",
            id: "change-\(currentLegIndex)",
            line: next.line
        )
        updateLiveActivity()
        checkMissedConnection()
    }

    private func notifyApproach(stops: Int, leg: T2CJourneyLeg) {
        let id = "approach-\(currentLegIndex)-\(stops)"
        guard !sentNotifications.contains(id) else { return }
        sentNotifications.insert(id)
        let nextLine = journey.legs.indices.contains(currentLegIndex + 1)
            ? " pour prendre la ligne \(journey.legs[currentLegIndex + 1].line.shortName)"
            : ""
        notify(
            title: stops == 1 ? "Descente au prochain arrêt" : "Descente dans 2 arrêts",
            body: "Descendez à \(leg.destination.name)\(nextLine).",
            id: id,
            line: leg.line
        )
    }

    private func checkMissedConnection() {
        guard phase == .waiting,
              currentLegIndex > 0,
              let leg = currentLeg,
              Date() > leg.departureAt.addingTimeInterval(60),
              !recalculating else { return }
        recalculating = true
        Task {
            defer { recalculating = false }
            guard let final = journey.legs.last?.destination,
                  let replacement = try? await T2CService.shared.calculateJourneys(
                    from: leg.origin,
                    to: final,
                    departureDate: .now
                  ).first else { return }
            journey = replacement
            currentLegIndex = 0
            currentStopIndex = 0
            visitedOrigin = true
            phase = .waiting
            notify(
                title: "Trajet actualisé",
                body: "Nouvelle proposition : ligne \(replacement.legs.first?.line.shortName ?? "T2C") à \(replacement.departureAt.formatted(date: .omitted, time: .shortened)).",
                id: "recalculated-\(Int(Date().timeIntervalSince1970))",
                line: replacement.legs.first?.line
            )
            updateLiveActivity()
        }
    }

    private func distance(from location: CLLocation, to station: NearbyStation) -> CLLocationDistance {
        station.platforms.compactMap { platform in
            guard let latitude = platform.latitude, let longitude = platform.longitude else { return nil }
            return location.distance(from: CLLocation(latitude: latitude, longitude: longitude))
        }.min() ?? .greatestFiniteMagnitude
    }

    private func updateLiveActivity(startIfNeeded: Bool = false) {
        guard let leg = currentLeg else { return }
        let phaseName: String
        switch phase {
        case .waiting: phaseName = "En attente"
        case .onBoard: phaseName = "À bord"
        case .changing: phaseName = "Correspondance"
        case .completed: phaseName = "Arrivé"
        }
        liveActivity.update(
            journeyID: journey.id,
            leg: leg,
            currentStopIndex: currentStopIndex,
            phase: phaseName,
            startIfNeeded: startIfNeeded
        )
    }

    private func notify(title: String, body: String, id: String, line: T2CLine? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let line, let attachment = LineNotificationAttachment.make(for: line) {
            content.attachments = [attachment]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

private enum LineNotificationAttachment {
    static func make(for line: T2CLine) -> UNNotificationAttachment? {
        let size = CGSize(width: 240, height: 168)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(hexNotification: line.colorHex).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let compactName = line.shortName.replacingOccurrences(of: " ", with: "")
            let hasPrefix = compactName.count > 1 && "ESP".contains(compactName.prefix(1).uppercased())
            if hasPrefix {
                UIColor.black.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 58, height: size.height))
            }

            let text = hasPrefix ? String(compactName.dropFirst()) : compactName
            let textRect = CGRect(x: hasPrefix ? 58 : 0, y: 0, width: size.width - (hasPrefix ? 58 : 0), height: size.height)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 92, weight: .heavy),
                .foregroundColor: UIColor(hexNotification: line.textColorHex),
                .paragraphStyle: paragraph
            ]
            let measured = text.size(withAttributes: attributes)
            text.draw(
                in: CGRect(x: textRect.minX, y: (size.height - measured.height) / 2, width: textRect.width, height: measured.height),
                withAttributes: attributes
            )

            if hasPrefix {
                let prefix = String(compactName.prefix(1)).uppercased()
                let prefixAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 48, weight: .heavy),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph
                ]
                let prefixSize = prefix.size(withAttributes: prefixAttributes)
                prefix.draw(
                    in: CGRect(x: 0, y: (size.height - prefixSize.height) / 2, width: 58, height: prefixSize.height),
                    withAttributes: prefixAttributes
                )
            }
        }

        let safeID = line.routeID.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clermontard-line-\(safeID).png")
        guard let data = image.pngData(), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "line-\(safeID)", url: url)
    }
}

private extension UIColor {
    convenience init(hexNotification: String) {
        let cleaned = hexNotification.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

#Preview {
    NavigationStack {
        Text("Sélectionnez un itinéraire pour afficher son suivi.")
    }
}
