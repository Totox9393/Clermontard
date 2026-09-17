//
//  HomeViewModel.swift
//  Clermontard
//

import Foundation
import Combine
import CoreLocation

@MainActor
final class HomeViewModel: NSObject, ObservableObject, CLLocationManagerDelegate {

    // MARK: - Données T2C

    @Published var lines: [T2CLine] = []
    @Published var stations: [NearbyStation] = []
    @Published var globalAlerts: [T2CAlert] = []
    @Published var trafficUnavailable = false

    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: - Localisation

    @Published var location: CLLocation?

    @Published var locationMessage =
        "Recherche de votre position…"

    @Published var locationDenied = false

    private let manager = CLLocationManager()

    private var locationTimeout: Task<Void, Never>?

    private var locating = false

    /// Meilleure position obtenue pendant la recherche.
    /// Permet de conserver une position même si elle n'atteint
    /// pas une précision parfaite.
    private var bestLocation: CLLocation?

    /// Indique qu'on souhaite réellement utiliser la localisation.
    /// Évite certains appels inutiles lorsque CLLocationManager
    /// initialise son delegate.
    private var wantsLocation = false
    private var refreshingAlerts = false

    /// Informations assez larges pour concerner l'accueil : réseau entier,
    /// plusieurs lignes ou interruption majeure du tramway.
    var generalAlerts: [T2CAlert] {
        globalAlerts.filter(isGeneralCurrentAlert)
    }

    // MARK: - Init

    override init() {

        super.init()

        manager.delegate = self

        // Suffisant pour rechercher les arrêts à proximité.
        manager.desiredAccuracy = kCLLocationAccuracyBest

        // Évite de recevoir énormément de mises à jour identiques.
        manager.distanceFilter = 10
    }

    // MARK: - Lancer la localisation

    func locate() {

        wantsLocation = true

        switch manager.authorizationStatus {

        case .notDetermined:

            locationDenied = false

            locationMessage =
                "Autorisez la localisation pour afficher les arrêts à proximité."

            manager.requestWhenInUseAuthorization()

        case .authorizedAlways,
             .authorizedWhenInUse:

            startLocating()

        case .denied,
             .restricted:

            stopLocating()

            location = nil

            locationDenied = true

            locationMessage =
                "Localisation désactivée. Vous pouvez rechercher votre arrêt par son nom."

        @unknown default:

            stopLocating()

            locationMessage =
                "Localisation indisponible. Recherchez votre arrêt par son nom."
        }
    }

    // MARK: - Commencer réellement la recherche GPS

    private func startLocating() {

        guard !locating else {
            return
        }

        locationDenied = false

        locationMessage =
            "Recherche de votre position…"

        locating = true

        bestLocation = nil

        manager.startUpdatingLocation()

        // Sécurité :
        // on ne laisse pas le GPS tourner indéfiniment.
        locationTimeout?.cancel()

        locationTimeout = Task { [weak self] in

            do {

                try await Task.sleep(
                    nanoseconds: 20_000_000_000
                )

            } catch {

                return
            }

            guard let self else {
                return
            }

            // Si on a réussi à obtenir une position,
            // même moins précise que souhaité,
            // on l'utilise quand même.
            if let bestLocation = self.bestLocation {

                self.acceptLocation(
                    bestLocation
                )

                return
            }

            self.stopLocating()

            self.locationMessage =
                "Position indisponible. Réessayez à l’extérieur ou recherchez votre arrêt."
        }
    }

    // MARK: - Permission modifiée

    func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {

        guard wantsLocation else {
            return
        }

        switch manager.authorizationStatus {

        case .authorizedAlways,
             .authorizedWhenInUse:

            startLocating()

        case .denied,
             .restricted:

            stopLocating()

            location = nil

            locationDenied = true

            locationMessage =
                "Localisation désactivée. Vous pouvez rechercher votre arrêt par son nom."

        case .notDetermined:

            // On attend simplement la réponse de l'utilisateur.
            break

        @unknown default:

            stopLocating()

            locationMessage =
                "Localisation indisponible."
        }
    }

    // MARK: - Arrêter le GPS

    func stopLocating() {

        manager.stopUpdatingLocation()

        locationTimeout?.cancel()

        locationTimeout = nil

        locating = false
    }

    // MARK: - Nouvelle position reçue

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {

        guard locating else {
            return
        }

        let validLocations = locations.filter { location in

            CLLocationCoordinate2DIsValid(
                location.coordinate
            )

            && location.horizontalAccuracy >= 0

            // Une localisation vieille de plusieurs minutes
            // ne nous intéresse pas.
            && abs(
                location.timestamp.timeIntervalSinceNow
            ) <= 60
        }

        guard !validLocations.isEmpty else {

            locationMessage =
                "Affinement de votre position…"

            return
        }

        // On prend d'abord la position la plus récente.
        guard let latest = validLocations.max(
            by: {
                $0.timestamp < $1.timestamp
            }
        ) else {
            return
        }

        // On conserve la meilleure précision reçue.
        if bestLocation == nil
            || latest.horizontalAccuracy
                < bestLocation!.horizontalAccuracy {

            bestLocation = latest
        }

        // Si l'utilisateur utilise une localisation approximative,
        // il est inutile d'attendre une précision GPS à 20 mètres.
        if manager.accuracyAuthorization
            == .reducedAccuracy {

            acceptLocation(
                latest
            )

            return
        }

        /*
         Avant tu exigeais <= 50 mètres.

         C'était trop strict :
         un iPhone peut facilement renvoyer 60, 100 ou 150 mètres
         pendant quelques secondes.

         Pour trouver les 4 arrêts T2C proches,
         150 mètres est largement suffisant.
         */

        if latest.horizontalAccuracy <= 150 {

            acceptLocation(
                latest
            )

        } else {

            locationMessage =
                "Affinement de votre position… précision actuelle ±\(Int(latest.horizontalAccuracy.rounded(.up))) m"
        }
    }

    // MARK: - Accepter une localisation

    private func acceptLocation(
        _ newLocation: CLLocation
    ) {

        location = newLocation

        stopLocating()

        if manager.accuracyAuthorization
            == .reducedAccuracy {

            locationMessage =
                "Position approximative · activez « Position exacte » pour améliorer les résultats."

        } else {

            locationMessage =
                "Arrêts à proximité de votre position"
        }
    }

    // MARK: - Erreur CoreLocation

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {

        if let locationError =
            error as? CLError {

            switch locationError.code {

            case .locationUnknown:

                // Erreur temporaire.
                // On laisse le GPS continuer à chercher.
                return

            case .denied:

                stopLocating()

                location = nil

                locationDenied = true

                locationMessage =
                    "Localisation refusée. Vous pouvez rechercher votre arrêt par son nom."

                return

            default:
                break
            }
        }

        // Si on avait malgré tout récupéré une position
        // utilisable avant l'erreur, on la conserve.
        if let bestLocation {

            acceptLocation(
                bestLocation
            )

            return
        }

        stopLocating()

        location = nil

        locationMessage =
            "Position indisponible. Vous pouvez rechercher un arrêt ou réessayer."
    }

    // MARK: - Distance d'un arrêt

    func distance(
        to station: NearbyStation
    ) -> Double? {

        guard let location else {
            return nil
        }

        let distances =
            station.platforms.compactMap {
                platform -> Double? in

                guard
                    let latitude =
                        platform.latitude,

                    let longitude =
                        platform.longitude,

                    latitude.isFinite,

                    longitude.isFinite,

                    (-90...90).contains(
                        latitude
                    ),

                    (-180...180).contains(
                        longitude
                    )

                else {

                    return nil
                }

                let stationLocation =
                    CLLocation(
                        latitude: latitude,
                        longitude: longitude
                    )

                return location.distance(
                    from: stationLocation
                )
            }

        return distances.min()
    }

    // MARK: - 4 arrêts les plus proches

    // MARK: - 4 arrêts les plus proches

    var nearest: [NearbyStation] {

        guard location != nil else {
            return []
        }

        let stationsWithDistance: [(station: NearbyStation, distance: CLLocationDistance)] =
            stations.compactMap { station -> (station: NearbyStation, distance: CLLocationDistance)? in

                guard let stationDistance = self.distance(to: station) else {
                    return nil
                }

                return (
                    station: station,
                    distance: stationDistance
                )
            }

        let sortedStations = stationsWithDistance.sorted { first, second in

            if first.distance == second.distance {
                return first.station.id < second.station.id
            }

            return first.distance < second.distance
        }

        return Array(
            sortedStations
                .prefix(4)
                .map { $0.station }
        )
    }

    // MARK: - Recherche d'arrêt

    func search(
        _ query: String
    ) -> [NearbyStation] {

        let cleanedQuery =
            query
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

        guard !cleanedQuery.isEmpty else {
            return []
        }

        return stations
            .filter { station in

                StationSearch.matches(station.name, query: cleanedQuery)
            }
            .sorted {

                $0.name
                    .localizedStandardCompare(
                        $1.name
                    )
                    == .orderedAscending
            }
    }

    // MARK: - Informations réseau

    func refreshGlobalAlerts() async {
        guard !refreshingAlerts else { return }
        refreshingAlerts = true
        defer { refreshingAlerts = false }

        do {
            globalAlerts = try await T2CService.shared.getGlobalAlerts()
            trafficUnavailable = false
        } catch {
            // Une coupure momentanée ne doit pas faire clignoter l'accueil.
            trafficUnavailable = true
        }
    }

    private func isGeneralCurrentAlert(_ alert: T2CAlert) -> Bool {
        let content = "\(alert.title) \(alert.text)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = content.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "fr_FR")
        )

        guard !content.isEmpty,
              !normalized.contains("aucun message"),
              !normalized.contains("aucune perturbation"),
              normalized != "inconnu" else { return false }

        let now = Date()
        if let start = parsedAlertDate(alert.startDatetime), start > now { return false }
        if let end = parsedAlertDate(alert.endDatetime), end < now { return false }

        let routes = Set(alert.affectedRoutes.filter { !$0.isEmpty })
        if routes.isEmpty || routes.count > 1 { return true }

        let generalPhrases = ["mouvement social", "greve", "reseau perturbe"]
        if generalPhrases.contains(where: { normalized.contains($0) }) { return true }

        let tramReferences = Set(lines.filter(\.isTram).flatMap { [$0.routeID, $0.shortName] })
        let affectsTram = !routes.isDisjoint(with: tramReferences)
        let interruptionPhrases = [
            "service interrompu", "circulation interrompue", "ne circule pas",
            "tramway a l'arret", "tram a l'arret"
        ]
        return affectsTram && interruptionPhrases.contains { normalized.contains($0) }
    }

    private func parsedAlertDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Paris")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    // MARK: - Chargement initial

    func load() async {

        guard !isLoading else {
            return
        }

        isLoading = true

        errorMessage = nil

        defer {

            isLoading = false
        }

        // -------------------------
        // ARRÊTS
        // -------------------------

        do {

            stations =
                try await T2CService
                    .shared
                    .getStations()

            if stations.isEmpty {

                errorMessage =
                    "Aucun arrêt disponible dans les données T2C."
            }

        } catch {

            errorMessage =
                "Impossible de charger les arrêts T2C. Vérifiez votre connexion et réessayez."
        }

        // -------------------------
        // LIGNES
        // -------------------------

        do {

            lines =
                try await T2CService
                    .shared
                    .getLines()

        } catch {

            if errorMessage == nil {

                errorMessage =
                    "Impossible de charger les lignes T2C."
            }
        }

        // -------------------------
        // INFORMATIONS RÉSEAU
        // -------------------------

        await refreshGlobalAlerts()

        // -------------------------
        // LOCALISATION
        // -------------------------

        /*
         Important :
         on lance désormais automatiquement la recherche
         de position une fois les arrêts chargés.
         */

        if !stations.isEmpty {

            locate()
        }
    }
}
