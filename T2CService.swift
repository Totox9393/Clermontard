//
//  T2CService.swift
//  Clermontard
//

import Foundation
import CoreLocation
import ZIPFoundation

actor T2CService {

    static let shared = T2CService()

    private init() {}

    // MARK: - URLs

    private let datasetURL = URL(
        string: """
        https://www.data.gouv.fr/api/1/datasets/syndicat-mixte-des-transports-en-commun-de-lagglomeration-clermontoise-smtc-ac-reseau-t2c-gtfs-gtfs-rt/
        """
    )!

    private let globalAlertsURL = URL(
        string: "https://api.t2c.fr/siv/alerts/banners"
    )!

    private let timetableURL = URL(
        string: "https://qrcode.t2c.fr/api/timetable"
    )!

    // MARK: - Cache GTFS

    private var gtfsIndex: GTFSIndex?
    private var gtfsResourceURL: URL?
    private var lineShapeCache: [String: [T2CLineShape]] = [:]
    private var journeyDepartureCache: [String: JourneyDepartureCache] = [:]

    // MARK: - Lignes

    func getLines() async throws -> [T2CLine] {

        let gtfs = try await getGTFSIndex()

        return gtfs.lines
    }

    func getStations() async throws -> [NearbyStation] {
        try await getGTFSIndex().stations
    }

    /// Charge les tracés seulement à l'ouverture du plan. Le travail ZIP/CSV
    /// reste sur l'acteur du service et ne bloque donc pas l'interface.
    func getLineShapes(for routeID: String) async throws -> [T2CLineShape] {
        if let cached = lineShapeCache[routeID] { return cached }

        let resourceURL: URL
        if let gtfsResourceURL {
            resourceURL = gtfsResourceURL
        } else {
            resourceURL = try findGTFSURL(in: try await getDatasetMetadata())
            gtfsResourceURL = resourceURL
        }

        let (temporaryURL, response) = try await URLSession.shared.download(from: resourceURL)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw T2CServiceError.invalidResponse
        }
        try Task.checkCancellation()

        let shapes = try await Task.detached(priority: .userInitiated) { [self] in
            let archive = try Archive(url: temporaryURL, accessMode: .read)
            let tripsText = try extractText("trips.txt", from: archive)
            let shapesText = try extractText("shapes.txt", from: archive)
            try Task.checkCancellation()
            return buildLineShapes(routeID: routeID, tripsText: tripsText, shapesText: shapesText)
        }.value
        if lineShapeCache.count >= 4 {
            lineShapeCache.removeAll(keepingCapacity: true)
        }
        lineShapeCache[routeID] = shapes
        return shapes
    }

    // MARK: - Calcul d'itinéraires

    func calculateJourneys(
        from origin: NearbyStation,
        to destination: NearbyStation,
        departureDate: Date = .now,
        limit: Int = 15,
        allowWalking: Bool = false
    ) async throws -> [T2CJourney] {
        guard origin.id != destination.id else { return [] }
        let gtfs = try await getGTFSIndex()
        let candidates = buildJourneyCandidates(
            from: origin,
            to: destination,
            index: gtfs,
            allowWalking: allowWalking
        )

        var journeys: [T2CJourney] = []
        let requestedDeparture = max(departureDate, .now)
        if allowWalking,
           let metres = walkingDistance(from: origin, to: destination),
           metres <= 1_200 {
            let walk = T2CWalkingSegment(
                origin: origin,
                destination: destination,
                distance: metres,
                duration: max(60, metres / 1.25)
            )
            journeys.append(T2CJourney(
                id: "walk|\(origin.id)|\(destination.id)|\(Int(requestedDeparture.timeIntervalSince1970))",
                legs: [],
                departureAt: requestedDeparture,
                arrivalAt: requestedDeparture.addingTimeInterval(walk.duration),
                directWalk: walk
            ))
        }
        for candidate in candidates.prefix(16) {
            var nextDeparture = requestedDeparture
            for _ in 0..<5 {
                guard let journey = await dateJourney(
                    candidate,
                    departureDate: nextDeparture
                ) else { break }
                journeys.append(journey)
                nextDeparture = journey.departureAt.addingTimeInterval(60)
            }
        }

        var unique: [String: T2CJourney] = [:]
        for journey in journeys {
            let signature = journey.legs.map { leg in
                let minute = Int(leg.departureAt.timeIntervalSince1970 / 60)
                return [
                    normalize(leg.line.shortName),
                    normalize(leg.origin.name),
                    normalize(leg.destination.name),
                    normalize(leg.direction),
                    String(minute)
                ].joined(separator: "|")
            }.joined(separator: ">")
            if let existing = unique[signature] {
                if journey.arrivalAt < existing.arrivalAt { unique[signature] = journey }
            } else {
                unique[signature] = journey
            }
        }

        return Array(unique.values)
            .filter { $0.departureAt >= Date().addingTimeInterval(-30) }
            .sorted {
                if $0.departureAt != $1.departureAt { return $0.departureAt < $1.departureAt }
                return $0.arrivalAt < $1.arrivalAt
            }
            .prefix(max(limit, 1))
            .map { $0 }
    }

    private func buildJourneyCandidates(
        from origin: NearbyStation,
        to destination: NearbyStation,
        index: GTFSIndex,
        allowWalking: Bool
    ) -> [[JourneyCandidateLeg]] {
        let stationsByID = Dictionary(uniqueKeysWithValues: index.stations.map { ($0.id, $0) })
        let stationIDByStop = Dictionary(
            index.stations.flatMap { station in station.platforms.map { ($0.id, station.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        let linesByID = Dictionary(uniqueKeysWithValues: index.lines.map { ($0.routeID, $0) })

        var patterns: [JourneyPattern] = []
        for line in index.lines {
            for direction in index.directionsByRoute[line.routeID] ?? [] {
                let key = makeDirectionKey(
                    routeID: line.routeID,
                    directionID: direction.directionID,
                    directionName: direction.name
                )
                var stationIDs: [String] = []
                for stop in index.stopsByDirection[key] ?? [] {
                    guard let stationID = stationIDByStop[stop.stopID], stationID != stationIDs.last else { continue }
                    stationIDs.append(stationID)
                }
                if stationIDs.count > 1 {
                    patterns.append(JourneyPattern(lineID: line.routeID, direction: direction.name, stationIDs: stationIDs))
                }
            }
        }

        var patternsByStation: [String: [JourneyPattern]] = [:]
        for pattern in patterns {
            for stationID in Set(pattern.stationIDs) {
                patternsByStation[stationID, default: []].append(pattern)
            }
        }

        struct State {
            let stationID: String
            let legs: [JourneyCandidateLeg]
            let stopTotal: Int
        }
        var queue = [State(stationID: origin.id, legs: [], stopTotal: 0)]
        var cursor = 0
        var bestDepth: [String: Int] = [origin.id + "|": 0]
        var results: [State] = []

        while cursor < queue.count, results.count < 60 {
            let state = queue[cursor]
            cursor += 1
            guard state.legs.count < 3 else { continue }
            let previousLineID = state.legs.last?.line.routeID

            var boardingOptions: [(stationID: String, walk: T2CWalkingSegment?)] = [(state.stationID, nil)]
            if allowWalking, let current = stationsByID[state.stationID] {
                var nearby: [(stationID: String, walk: T2CWalkingSegment?)] = []
                for candidate in index.stations where candidate.id != current.id {
                    guard let metres = walkingDistance(from: current, to: candidate), metres <= 900 else { continue }
                    let segment = T2CWalkingSegment(
                        origin: current,
                        destination: candidate,
                        distance: metres,
                        duration: max(60, metres / 1.25)
                    )
                    nearby.append((stationID: candidate.id, walk: segment))
                }
                nearby.sort { ($0.walk?.distance ?? 0) < ($1.walk?.distance ?? 0) }
                boardingOptions.append(contentsOf: nearby.prefix(8))
            }

            for option in boardingOptions {
              for pattern in patternsByStation[option.stationID] ?? [] where pattern.lineID != previousLineID {
                guard let start = pattern.stationIDs.firstIndex(of: option.stationID),
                      start < pattern.stationIDs.count - 1,
                      let line = linesByID[pattern.lineID],
                      let fromStation = stationsByID[option.stationID] else { continue }

                for end in (start + 1)..<pattern.stationIDs.count {
                    let nextID = pattern.stationIDs[end]
                    guard let toStation = stationsByID[nextID] else { continue }
                    let leg = JourneyCandidateLeg(
                        line: line,
                        origin: fromStation,
                        destination: toStation,
                        stations: pattern.stationIDs[start...end].compactMap { stationsByID[$0] },
                        direction: pattern.direction,
                        stopCount: end - start,
                        walkBefore: option.walk
                    )
                    let next = State(
                        stationID: nextID,
                        legs: state.legs + [leg],
                        stopTotal: state.stopTotal + end - start
                    )
                    if nextID == destination.id {
                        results.append(next)
                        continue
                    }
                    let key = nextID + "|" + line.routeID
                    let depth = next.legs.count
                    if depth <= (bestDepth[key] ?? Int.max) {
                        bestDepth[key] = depth
                        queue.append(next)
                    }
                }
              }
            }
        }

        var unique: [String: State] = [:]
        for result in results {
            let key = result.legs.map { $0.line.routeID + ":" + $0.origin.id + ">" + $0.destination.id }.joined(separator: "|")
            if unique[key] == nil { unique[key] = result }
        }
        return unique.values.sorted {
            if $0.legs.count != $1.legs.count { return $0.legs.count < $1.legs.count }
            return $0.stopTotal < $1.stopTotal
        }.prefix(8).map(\.legs)
    }

    private func dateJourney(
        _ candidate: [JourneyCandidateLeg],
        departureDate: Date
    ) async -> T2CJourney? {
        var readyAt = departureDate
        var datedLegs: [T2CJourneyLeg] = []

        for (index, leg) in candidate.enumerated() {
            if let walk = leg.walkBefore { readyAt = readyAt.addingTimeInterval(walk.duration) }
            if index > 0 { readyAt = readyAt.addingTimeInterval(180) }
            let allDepartures = await journeyDepartures(for: leg)
                .filter { $0.dueAt >= readyAt.addingTimeInterval(-30) && !$0.isCancelled }
            let matchingDirection = allDepartures.filter { departure in
                guard let destination = departure.destination, !destination.isEmpty else { return false }
                let left = normalize(destination)
                let right = normalize(leg.direction)
                return left.contains(right) || right.contains(left)
            }
            guard let selectedDeparture = (matchingDirection.isEmpty ? allDepartures : matchingDirection)
                .min(by: { $0.dueAt < $1.dueAt }) else { return nil }

            let departAt = selectedDeparture.dueAt
            let secondsPerStop: TimeInterval = leg.line.isTram ? 105 : 135
            let arriveAt = departAt.addingTimeInterval(Double(max(leg.stopCount, 1)) * secondsPerStop)
            let buffer = index == 0 ? nil : departAt.timeIntervalSince(datedLegs[index - 1].arrivalAt)
            datedLegs.append(T2CJourneyLeg(
                id: "\(index)|\(leg.line.routeID)|\(leg.origin.id)|\(leg.destination.id)",
                line: leg.line,
                origin: leg.origin,
                destination: leg.destination,
                stations: leg.stations,
                direction: leg.direction,
                stopCount: leg.stopCount,
                departureAt: departAt,
                arrivalAt: arriveAt,
                isRealtime: selectedDeparture.isRealtime,
                transferBuffer: buffer,
                walkBefore: leg.walkBefore
            ))
            readyAt = arriveAt
        }

        guard let first = datedLegs.first, let last = datedLegs.last else { return nil }
        return T2CJourney(
            id: datedLegs.map(\.id).joined(separator: "|") + "|\(Int(first.departureAt.timeIntervalSince1970))",
            legs: datedLegs,
            departureAt: first.departureAt,
            arrivalAt: last.arrivalAt,
            directWalk: nil
        )
    }

    private func walkingDistance(from lhs: NearbyStation, to rhs: NearbyStation) -> CLLocationDistance? {
        let left = lhs.platforms.compactMap { platform -> CLLocation? in
            guard let latitude = platform.latitude, let longitude = platform.longitude else { return nil }
            return CLLocation(latitude: latitude, longitude: longitude)
        }
        let right = rhs.platforms.compactMap { platform -> CLLocation? in
            guard let latitude = platform.latitude, let longitude = platform.longitude else { return nil }
            return CLLocation(latitude: latitude, longitude: longitude)
        }
        return left.flatMap { a in right.map { a.distance(from: $0) } }.min()
    }

    private func journeyDepartures(for leg: JourneyCandidateLeg) async -> [T2CDeparture] {
        let cacheKey = leg.origin.id + "|" + leg.line.routeID
        if let cached = journeyDepartureCache[cacheKey],
           Date().timeIntervalSince(cached.loadedAt) < 20 {
            return cached.departures
        }

        var departures: [T2CDeparture] = []
        for platform in leg.origin.platforms where platform.routeIDs.contains(leg.line.routeID) {
            guard let result = try? await getTimetable(stopID: platform.id, line: leg.line, limit: 40) else { continue }
            departures.append(contentsOf: result.realtimeDepartures)
            departures.append(contentsOf: result.theoreticalDepartures)
        }
        var unique: [String: T2CDeparture] = [:]
        for departure in departures where !departure.isCancelled {
            let key = "\(Int(departure.dueAt.timeIntervalSince1970))|\(normalize(departure.destination ?? ""))"
            if unique[key] == nil || (departure.isRealtime && unique[key]?.isRealtime != true) {
                unique[key] = departure
            }
        }
        let sorted = unique.values.sorted { $0.dueAt < $1.dueAt }
        journeyDepartureCache[cacheKey] = JourneyDepartureCache(loadedAt: .now, departures: sorted)
        return sorted
    }

    // MARK: - Directions

    func getDirections(
        for lineID: String
    ) async throws -> [T2CDirection] {

        let gtfs = try await getGTFSIndex()

        return gtfs.directionsByRoute[lineID] ?? []
    }

    // MARK: - Arrêts

    func getStops(
        for lineID: String,
        direction: T2CDirection
    ) async throws -> [T2CStop] {

        let gtfs = try await getGTFSIndex()

        let key = makeDirectionKey(
            routeID: lineID,
            directionID: direction.directionID,
            directionName: direction.name
        )

        return gtfs.stopsByDirection[key] ?? []
    }

    // MARK: - Alertes globales

    func getGlobalAlerts() async throws -> [T2CAlert] {

        let (data, response) =
            try await URLSession.shared.data(
                from: globalAlertsURL
            )

        guard let httpResponse =
                response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode
        else {
            throw T2CServiceError.invalidResponse
        }

        return try JSONDecoder().decode(
            [T2CAlert].self,
            from: data
        )
    }

    // MARK: - Alertes ligne

    func getAlerts(
        for lineID: String
    ) async throws -> [T2CAlert] {

        guard let encodedLineID =
                lineID.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                )
        else {
            throw T2CServiceError.invalidURL
        }

        var components = URLComponents(
            string:
                "https://api.t2c.fr/siv/alerts/by-line/\(encodedLineID)"
        )

        components?.queryItems = [
            URLQueryItem(
                name: "type",
                value: "Trafic"
            )
        ]

        guard let url = components?.url else {
            throw T2CServiceError.invalidURL
        }

        let (data, response) =
            try await URLSession.shared.data(
                from: url
            )

        guard let httpResponse =
                response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode
        else {
            throw T2CServiceError.invalidResponse
        }

        return try JSONDecoder().decode(
            [T2CAlert].self,
            from: data
        )
    }

    // MARK: - Horaires

    func getTimetable(
        stopID: String,
        line: T2CLine,
        limit: Int = 10
    ) async throws -> T2CTimetableResult {

        var components = URLComponents(
            url: timetableURL,
            resolvingAgainstBaseURL: false
        )

        components?.queryItems = [
            URLQueryItem(
                name: "_stop_code",
                value: stopID
            ),
            URLQueryItem(
                name: "_limit",
                value: String(max(limit * 5, 40))
            )
        ]

        guard let url = components?.url else {
            throw T2CServiceError.invalidURL
        }

        let (data, response) =
            try await URLSession.shared.data(
                from: url
            )

        guard let httpResponse =
                response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode
        else {
            throw T2CServiceError.invalidResponse
        }

        let rawResponse = try JSONDecoder().decode(
            RawTimetableResponse.self,
            from: data
        )

        let rawDepartures =
            rawResponse.timetable?.timetable ?? []

        let referencedLineIDs = Set(
            (rawResponse.referentialLine ?? [])
                .filter { normalize($0.shortName) == normalize(line.shortName) }
                .map { normalize($0.lineID) }
        )

        var realtime: [T2CDeparture] = []
        var theoretical: [T2CDeparture] = []
        var cancelled: [T2CDeparture] = []

        for raw in rawDepartures {

            guard matchesLine(raw.lineID, line: line)
                    || raw.lineID.map { referencedLineIDs.contains(normalize($0)) } == true else {
                continue
            }

            let scheduledDate =
                parseT2CDate(raw.datetime)

            let estimatedDate =
                parseT2CDate(
                    raw.datetimeEstimated
                )

            guard let dueDate =
                    estimatedDate ?? scheduledDate
            else {
                continue
            }

            let departure = T2CDeparture(
                routeID: raw.lineID,
                routeName: line.shortName,
                stopID: stopID,
                destination: raw.destination,
                dueAt: dueDate,
                scheduledAt: scheduledDate,
                estimatedAt: estimatedDate,
                status: raw.departureStatus,
                theoretical: raw.theoretical,
                info: cleanHTML(raw.info ?? "")
            )

            if departure.isCancelled {

                cancelled.append(
                    departure
                )

            } else if departure.isRealtime {

                realtime.append(
                    departure
                )

            } else {

                theoretical.append(
                    departure
                )
            }
        }

        // Le référentiel QR T2C peut rester sur l'ancienne numérotation alors
        // que le GTFS public contient déjà la nouvelle ligne. Dans ce cas, on
        // affiche les horaires théoriques officiels du GTFS au lieu d'annoncer
        // à tort qu'aucun passage n'existe.
        if realtime.isEmpty, theoretical.isEmpty, cancelled.isEmpty,
           let gtfsIndex {
            let key = stopID + "|" + line.routeID
            let now = Date()
            theoretical = (gtfsIndex.scheduledDeparturesByStopAndRoute[key] ?? [])
                .filter {
                    $0.dueAt >= now.addingTimeInterval(-60)
                        && $0.dueAt <= now.addingTimeInterval(6 * 3600)
                }
                .prefix(limit)
                .map {
                    T2CDeparture(
                        routeID: line.routeID,
                        routeName: line.shortName,
                        stopID: stopID,
                        destination: $0.destination,
                        dueAt: $0.dueAt,
                        scheduledAt: $0.dueAt,
                        estimatedAt: nil,
                        status: nil,
                        theoretical: true,
                        info: nil
                    )
                }
        }

        realtime.sort {
            $0.dueAt < $1.dueAt
        }

        theoretical.sort {
            $0.dueAt < $1.dueAt
        }

        cancelled.sort {
            $0.dueAt < $1.dueAt
        }

        let messages = (rawResponse.message ?? [])
            .compactMap { raw -> T2CInfoMessage? in

                guard
                    let title = raw.title,
                    let content = raw.content
                else {
                    return nil
                }

                let lineRefs =
                    raw.lineRefs ?? []

                if !lineRefs.isEmpty {

                    let applies =
                        lineRefs.contains(
                            line.routeID
                        )
                        || lineRefs.contains(
                            line.shortName
                        )

                    if !applies {
                        return nil
                    }
                }

                return T2CInfoMessage(
                    messageID: raw.id ?? "",
                    title: title,
                    content: cleanHTML(content),
                    validFrom: raw.validStartTime,
                    validUntil: raw.validUntilTime,
                    lineRefs: lineRefs,
                    stopRefs: raw.stopRefs ?? []
                )
            }

        return T2CTimetableResult(
            realtimeDepartures:
                Array(realtime.prefix(limit)),
            theoreticalDepartures:
                Array(theoretical.prefix(limit)),
            cancelledDepartures:
                Array(cancelled.prefix(limit)),
            messages: messages
        )
    }

    // MARK: - GTFS

    private func getGTFSIndex() async throws
        -> GTFSIndex {

        if let gtfsIndex {
            return gtfsIndex
        }

        let metadata =
            try await getDatasetMetadata()

        let gtfsURL =
            try findGTFSURL(
                in: metadata
            )
        gtfsResourceURL = gtfsURL

        let (temporaryURL, response) =
            try await URLSession.shared.download(
                from: gtfsURL
            )

        guard let httpResponse =
                response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode
        else {
            throw T2CServiceError.invalidResponse
        }

        let index =
            try buildGTFSIndex(
                archiveURL: temporaryURL
            )

        self.gtfsIndex = index

        return index
    }

    private func getDatasetMetadata() async throws
        -> DatasetMetadata {

        let (data, response) =
            try await URLSession.shared.data(
                from: datasetURL
            )

        guard let httpResponse =
                response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode
        else {
            throw T2CServiceError.invalidResponse
        }

        return try JSONDecoder().decode(
            DatasetMetadata.self,
            from: data
        )
    }

    private func findGTFSURL(
        in metadata: DatasetMetadata
    ) throws -> URL {

        var candidates:
            [(score: Int, url: URL)] = []

        for resource in metadata.resources {

            let format =
                resource.format?
                    .lowercased()
                ?? ""

            let title =
                resource.title?
                    .lowercased()
                ?? ""

            let mime =
                resource.mime?
                    .lowercased()
                ?? ""

            let type =
                resource.type?
                    .lowercased()
                ?? ""

            let isGTFS =
                format == "gtfs"
                || title == "gtfs"
                || (
                    format == "zip"
                    && title.contains("gtfs")
                )
                || (
                    mime == "application/zip"
                    && title.contains("gtfs")
                )

            guard isGTFS else {
                continue
            }

            guard
                let rawURL =
                    resource.latest
                    ?? resource.url,
                let url =
                    URL(string: rawURL)
            else {
                continue
            }

            var score = 0

            if type == "main" {
                score += 20
            }

            if format == "zip"
                || mime == "application/zip" {
                score += 10
            }

            candidates.append(
                (
                    score: score,
                    url: url
                )
            )
        }

        guard let best =
                candidates.max(
                    by: {
                        $0.score < $1.score
                    }
                )
        else {
            throw T2CServiceError.gtfsNotFound
        }

        return best.url
    }

    // MARK: - Construction index GTFS

    private func buildGTFSIndex(
        archiveURL: URL
    ) throws -> GTFSIndex {

        let archive = try Archive(
            url: archiveURL,
            accessMode: .read
        )

        let routesText =
            try extractText(
                "routes.txt",
                from: archive
            )

        let stopsText =
            try extractText(
                "stops.txt",
                from: archive
            )

        let tripsText =
            try extractText(
                "trips.txt",
                from: archive
            )

        let stopTimesText =
            try extractText(
                "stop_times.txt",
                from: archive
            )

        let calendarText = try extractText("calendar.txt", from: archive)
        let calendarDatesText = try extractText("calendar_dates.txt", from: archive)

        let lines =
            parseRoutesCSV(
                routesText
            )

        let stops =
            parseStopsCSV(
                stopsText
            )

        let allowedRouteIDs = Set(lines.map(\.routeID))

        let trips = parseTripsCSV(tripsText).filter {
            allowedRouteIDs.contains($0.value.routeID)
        }

        let directions =
            buildDirections(
                trips: trips
            )

        let activeServiceDates = buildActiveServiceDates(
            calendarText: calendarText,
            calendarDatesText: calendarDatesText,
            around: .now
        )

        let routeData =
            buildRouteStopsStreaming(
                stopTimesText: stopTimesText,
                trips: trips,
                stops: stops,
                activeServiceDates: activeServiceDates
            )

        let routeStops = routeData.stops

        return GTFSIndex(
            stations: buildStations(text: stopsText, lines: lines, directions: directions, routeStops: routeStops),
            lines: lines,
            directionsByRoute:
                directions,
            stopsByDirection:
                routeStops,
            scheduledDeparturesByStopAndRoute:
                routeData.departures
        )
    }

    private func buildStations(text: String, lines: [T2CLine], directions: [String: [T2CDirection]], routeStops: [String: [T2CStop]]) -> [NearbyStation] {
        var routesByStop: [String: Set<String>] = [:]
        for line in lines {
            for direction in directions[line.routeID] ?? [] {
                let key = makeDirectionKey(routeID: line.routeID, directionID: direction.directionID, directionName: direction.name)
                for stop in routeStops[key] ?? [] {
                    routesByStop[stop.stopID, default: []].insert(line.routeID)
                }
            }
        }
        let rows = parseCSV(text)
        guard let first = rows.first else { return [] }
        let headers = normalizedHeaders(first)
        var stations: [NearbyStation] = []
        var indicesByName: [String: [Int]] = [:]
        for row in rows.dropFirst() {
            let id = value(row, at: headers.firstIndex(of: "stop_id"))
            guard let routes = routesByStop[id], !routes.isEmpty else { continue }
            let name = value(row, at: headers.firstIndex(of: "stop_name"))
            let parent = value(row, at: headers.firstIndex(of: "parent_station"))
            let lat = Double(value(row, at: headers.firstIndex(of: "stop_lat")))
            let lon = Double(value(row, at: headers.firstIndex(of: "stop_lon")))
            let platform = StationPlatform(id: id, latitude: lat, longitude: lon, routeIDs: routes)
            let key = parent.isEmpty ? normalize(name) : "parent:" + parent
            let existing = (indicesByName[key] ?? []).first { index in
                if !parent.isEmpty { return true }
                guard let lat, let lon, let other = stations[index].platforms.first,
                      let otherLat = other.latitude, let otherLon = other.longitude else { return false }
                let north = (lat - otherLat) * 111_320
                let east = (lon - otherLon) * 111_320 * cos(lat * .pi / 180)
                return hypot(north, east) < 300
            }
            let serving = lines.filter { routes.contains($0.routeID) }
            if let index = existing {
                stations[index].platforms.append(platform)
                stations[index].lines = Array(Set(stations[index].lines + serving)).sorted {
                    $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
                }
            } else {
                indicesByName[key, default: []].append(stations.count)
                stations.append(NearbyStation(id: id, name: name.isEmpty ? id : name, platforms: [platform], lines: serving))
            }
        }
        return stations.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated private func extractText(
        _ filename: String,
        from archive: Archive
    ) throws -> String {

        guard let entry =
                archive[filename]
        else {
            throw T2CServiceError.gtfsFileNotFound(
                filename
            )
        }

        var data = Data()

        _ = try archive.extract(
            entry,
            consumer: { chunk in
                data.append(chunk)
            }
        )

        guard let text =
                String(
                    data: data,
                    encoding: .utf8
                )
        else {
            throw T2CServiceError.invalidGTFS
        }

        return text
    }

    // MARK: - Routes

    private func parseRoutesCSV(
        _ text: String
    ) -> [T2CLine] {

        let rows = parseCSV(text)

        guard let firstRow =
                rows.first
        else {
            return []
        }

        let headers =
            normalizedHeaders(
                firstRow
            )

        guard
            let routeIDIndex =
                headers.firstIndex(
                    of: "route_id"
                ),
            let shortNameIndex =
                headers.firstIndex(
                    of: "route_short_name"
                )
        else {
            return []
        }

        let longNameIndex =
            headers.firstIndex(
                of: "route_long_name"
            )

        let colorIndex =
            headers.firstIndex(
                of: "route_color"
            )

        let textColorIndex =
            headers.firstIndex(
                of: "route_text_color"
            )

        var result: [T2CLine] = []

        for row in rows.dropFirst() {

            let routeID =
                value(
                    row,
                    at: routeIDIndex
                )

            let shortName =
                value(
                    row,
                    at: shortNameIndex
                )

            guard
                !routeID.isEmpty,
                !shortName.isEmpty
            else {
                continue
            }

            // Exclude school/internal routes before building the stop catalogue.
            if shouldHideLine(shortName) { continue }

            let longName =
                value(
                    row,
                    at: longNameIndex
                )

            var color =
                value(
                    row,
                    at: colorIndex
                )

            var textColor =
                value(
                    row,
                    at: textColorIndex
                )

            if color.isEmpty {
                color = "3478F6"
            }

            if textColor.isEmpty {
                textColor = "FFFFFF"
            }

            if !color.hasPrefix("#") {
                color = "#\(color)"
            }

            if !textColor.hasPrefix("#") {
                textColor = "#\(textColor)"
            }

            result.append(
                T2CLine(
                    routeID: routeID,
                    shortName: shortName,
                    longName: longName,
                    colorHex: color,
                    textColorHex: textColor,
                    routeType: Int(value(row, at: headers.firstIndex(of: "route_type"))) ?? 3
                )
            )
        }

        var unique:
            [String: T2CLine] = [:]

        for line in result {
            unique[line.routeID] = line
        }

        return unique.values.sorted {

            $0.shortName
                .localizedStandardCompare(
                    $1.shortName
                )
                == .orderedAscending
        }
    }

    private func shouldHideLine(
        _ shortName: String
    ) -> Bool {

        let cleaned =
            shortName
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .uppercased()

        // Lignes scolaires / internes
        if cleaned.hasPrefix("LS") {
            return true
        }

        // 110, 120, 130 ... 430 etc.
        if let numeric =
                Int(cleaned),
           numeric >= 100 {
            return true
        }

        return false
    }

    // MARK: - Stops

    private func parseStopsCSV(
        _ text: String
    ) -> [String: String] {

        let rows = parseCSV(text)

        guard let firstRow =
                rows.first
        else {
            return [:]
        }

        let headers =
            normalizedHeaders(
                firstRow
            )

        guard
            let stopIDIndex =
                headers.firstIndex(
                    of: "stop_id"
                ),
            let stopNameIndex =
                headers.firstIndex(
                    of: "stop_name"
                )
        else {
            return [:]
        }

        var result:
            [String: String] = [:]

        for row in rows.dropFirst() {

            let stopID =
                value(
                    row,
                    at: stopIDIndex
                )

            let stopName =
                value(
                    row,
                    at: stopNameIndex
                )

            guard !stopID.isEmpty else {
                continue
            }

            result[stopID] =
                stopName.isEmpty
                ? stopID
                : stopName
        }

        return result
    }

    // MARK: - Trips

    nonisolated private func parseTripsCSV(
        _ text: String
    ) -> [String: TripInfo] {

        let rows = parseCSV(text)

        guard let firstRow =
                rows.first
        else {
            return [:]
        }

        let headers =
            normalizedHeaders(
                firstRow
            )

        guard
            let tripIDIndex =
                headers.firstIndex(
                    of: "trip_id"
                ),
            let routeIDIndex =
                headers.firstIndex(
                    of: "route_id"
                )
        else {
            return [:]
        }

        let directionIndex =
            headers.firstIndex(
                of: "direction_id"
            )

        let headsignIndex =
            headers.firstIndex(
                of: "trip_headsign"
            )

        let serviceIDIndex = headers.firstIndex(of: "service_id")
        let shapeIDIndex = headers.firstIndex(of: "shape_id")

        var result:
            [String: TripInfo] = [:]

        for row in rows.dropFirst() {

            let tripID =
                value(
                    row,
                    at: tripIDIndex
                )

            let routeID =
                value(
                    row,
                    at: routeIDIndex
                )

            guard
                !tripID.isEmpty,
                !routeID.isEmpty
            else {
                continue
            }

            let directionID =
                value(
                    row,
                    at: directionIndex
                )

            let headsign =
                value(
                    row,
                    at: headsignIndex
                )

            result[tripID] =
                TripInfo(
                    routeID: routeID,
                    serviceID: value(row, at: serviceIDIndex),
                    shapeID: value(row, at: shapeIDIndex),
                    directionID:
                        directionID,
                    headsign:
                        headsign
                )
        }

        return result
    }

    nonisolated private func buildLineShapes(
        routeID: String,
        tripsText: String,
        shapesText: String
    ) -> [T2CLineShape] {
        let descriptors = parseTripsCSV(tripsText).values
            .filter { $0.routeID == routeID && !$0.shapeID.isEmpty }

        var descriptorByShape: [String: TripInfo] = [:]
        for descriptor in descriptors where descriptorByShape[descriptor.shapeID] == nil {
            descriptorByShape[descriptor.shapeID] = descriptor
        }
        guard !descriptorByShape.isEmpty else { return [] }

        var shapeIDIndex: Int?
        var latitudeIndex: Int?
        var longitudeIndex: Int?
        var sequenceIndex: Int?
        var readHeader = false
        var pointsByShape: [String: [(sequence: Int, point: T2CShapePoint)]] = [:]

        shapesText.enumerateLines { line, _ in
            let row = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if !readHeader {
                let headers = self.normalizedHeaders(row)
                shapeIDIndex = headers.firstIndex(of: "shape_id")
                latitudeIndex = headers.firstIndex(of: "shape_pt_lat")
                longitudeIndex = headers.firstIndex(of: "shape_pt_lon")
                sequenceIndex = headers.firstIndex(of: "shape_pt_sequence")
                readHeader = true
                return
            }
            let shapeID = self.value(row, at: shapeIDIndex)
            guard descriptorByShape[shapeID] != nil,
                  let latitude = Double(self.value(row, at: latitudeIndex)),
                  let longitude = Double(self.value(row, at: longitudeIndex)) else { return }
            let sequence = Int(self.value(row, at: sequenceIndex)) ?? Int.max
            pointsByShape[shapeID, default: []].append((sequence, T2CShapePoint(latitude: latitude, longitude: longitude)))
        }

        // Plusieurs courses réutilisent des géométries proches, mais certaines
        // lignes ont aussi de vraies variantes de parcours pour une même
        // destination. On déduplique donc par géométrie plutôt que de supprimer
        // ces branches utiles.
        var bestByVariant: [String: T2CLineShape] = [:]
        for (shapeID, values) in pointsByShape {
            guard let descriptor = descriptorByShape[shapeID] else { continue }
            let points = values.sorted { $0.sequence < $1.sequence }.map(\.point)
            guard points.count > 1 else { continue }
            let sampleIndexes = [0, points.count / 4, points.count / 2, (points.count * 3) / 4, points.count - 1]
            let geometryKey = sampleIndexes.map { index in
                let point = points[index]
                return String(format: "%.3f,%.3f", point.latitude, point.longitude)
            }.joined(separator: "|")
            let key = descriptor.directionID + "|" + normalize(descriptor.headsign) + "|" + geometryKey
            let maximumPointCount = 600
            let stride = max(1, Int(ceil(Double(points.count) / Double(maximumPointCount))))
            var reducedPoints = Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }
            if reducedPoints.last != points.last, let last = points.last { reducedPoints.append(last) }
            let candidate = T2CLineShape(
                id: shapeID,
                directionID: descriptor.directionID,
                destination: descriptor.headsign,
                points: reducedPoints
            )
            if candidate.points.count > (bestByVariant[key]?.points.count ?? 0) {
                bestByVariant[key] = candidate
            }
        }
        // Un seul parcours officiel par sens/destination. Le plus complet
        // conserve les arrêts voyageurs des courses régulières, sans créer la
        // superposition illisible de plusieurs variantes.
        let limited = Dictionary(grouping: bestByVariant.values) {
            $0.directionID + "|" + normalize($0.destination)
        }.values.compactMap { variants in
            variants.max { approximateLength(of: $0) < approximateLength(of: $1) }
        }
        return limited.sorted {
            if $0.directionID != $1.directionID { return $0.directionID < $1.directionID }
            return $0.destination.localizedStandardCompare($1.destination) == .orderedAscending
        }
    }

    nonisolated private func approximateLength(of shape: T2CLineShape) -> Double {
        guard shape.points.count > 1 else { return 0 }
        return zip(shape.points, shape.points.dropFirst()).reduce(0) { total, pair in
            let latitude = (pair.0.latitude + pair.1.latitude) * .pi / 360
            let latitudeDelta = pair.1.latitude - pair.0.latitude
            let longitudeDelta = (pair.1.longitude - pair.0.longitude) * cos(latitude)
            return total + hypot(latitudeDelta, longitudeDelta)
        }
    }

    private var parisCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "fr_FR")
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    private func gtfsSeconds(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
    }

    private func buildActiveServiceDates(
        calendarText: String,
        calendarDatesText: String,
        around date: Date
    ) -> [String: [Date]] {
        let calendar = parisCalendar
        let dates = (-1...1).compactMap { calendar.date(byAdding: .day, value: $0, to: date) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd"

        let weekdayColumn = [
            1: "sunday", 2: "monday", 3: "tuesday", 4: "wednesday",
            5: "thursday", 6: "friday", 7: "saturday"
        ]
        var active: [String: Set<String>] = [:]
        let calendarRows = parseCSV(calendarText)
        if let header = calendarRows.first {
            let headers = normalizedHeaders(header)
            for row in calendarRows.dropFirst() {
                let serviceID = value(row, at: headers.firstIndex(of: "service_id"))
                let start = value(row, at: headers.firstIndex(of: "start_date"))
                let end = value(row, at: headers.firstIndex(of: "end_date"))
                guard !serviceID.isEmpty else { continue }
                for candidate in dates {
                    let code = formatter.string(from: candidate)
                    let weekday = calendar.component(.weekday, from: candidate)
                    guard code >= start, code <= end,
                          let column = weekdayColumn[weekday],
                          value(row, at: headers.firstIndex(of: column)) == "1" else { continue }
                    active[serviceID, default: []].insert(code)
                }
            }
        }

        let exceptionRows = parseCSV(calendarDatesText)
        if let header = exceptionRows.first {
            let headers = normalizedHeaders(header)
            let relevantCodes = Set(dates.map { formatter.string(from: $0) })
            for row in exceptionRows.dropFirst() {
                let serviceID = value(row, at: headers.firstIndex(of: "service_id"))
                let code = value(row, at: headers.firstIndex(of: "date"))
                guard relevantCodes.contains(code), !serviceID.isEmpty else { continue }
                if value(row, at: headers.firstIndex(of: "exception_type")) == "1" {
                    active[serviceID, default: []].insert(code)
                } else {
                    active[serviceID]?.remove(code)
                }
            }
        }

        return active.mapValues { codes in
            codes.compactMap { formatter.date(from: $0) }.sorted()
        }
    }

    // MARK: - Directions

    private func buildDirections(
        trips: [String: TripInfo]
    ) -> [String: [T2CDirection]] {

        var values:
            [String: [String: T2CDirection]] = [:]

        for trip in trips.values {

            guard
                !trip.headsign.isEmpty
            else {
                continue
            }

            let direction =
                T2CDirection(
                    directionID:
                        trip.directionID,
                    name:
                        trip.headsign
                )

            values[
                trip.routeID,
                default: [:]
            ][direction.id] = direction
        }

        var result:
            [String: [T2CDirection]] = [:]

        for (
            routeID,
            directions
        ) in values {

            result[routeID] =
                directions.values.sorted {

                    $0.name
                        .localizedStandardCompare(
                            $1.name
                        )
                        == .orderedAscending
                }
        }

        return result
    }

    // MARK: - Stops par direction

    /// `stop_times.txt` is the largest GTFS file. Processing each row as it is
    /// decoded avoids retaining hundreds of thousands of temporary arrays.
    private func buildRouteStopsStreaming(
        stopTimesText: String,
        trips: [String: TripInfo],
        stops: [String: String],
        activeServiceDates: [String: [Date]]
    ) -> (stops: [String: [T2CStop]], departures: [String: [GTFSScheduledDeparture]]) {
        var tripIDIndex: Int?
        var stopIDIndex: Int?
        var sequenceIndex: Int?
        var departureTimeIndex: Int?
        var pickupTypeIndex: Int?
        var hasReadHeader = false
        // Un même sens contient de nombreux voyages (journée, renforts et
        // services partiels). Les mélanger arrêt par arrêt produit un parcours
        // qui n'existe pas. Le fichier étant ordonné par voyage, on compare les
        // voyages complets au fil de la lecture sans les garder tous en mémoire.
        var bestTripByDirection: [String: [StopSequence]] = [:]
        var currentTripID: String?
        var currentTrip: TripInfo?
        var currentStops: [StopSequence] = []
        var scheduledDepartures: [String: [GTFSScheduledDeparture]] = [:]

        func keepCurrentTripIfNeeded() {
            guard let trip = currentTrip, !currentStops.isEmpty else {
                currentStops.removeAll(keepingCapacity: true)
                return
            }
            let key = makeDirectionKey(
                routeID: trip.routeID,
                directionID: trip.directionID,
                directionName: trip.headsign
            )
            let ordered = currentStops.sorted { $0.sequence < $1.sequence }
            let candidateCount = Set(ordered.map(\.stopID)).count
            let previousCount = Set(bestTripByDirection[key, default: []].map(\.stopID)).count
            if candidateCount > previousCount
                || (candidateCount == previousCount
                    && (ordered.last?.sequence ?? 0) > (bestTripByDirection[key]?.last?.sequence ?? 0)) {
                bestTripByDirection[key] = ordered
            }
            currentStops.removeAll(keepingCapacity: true)
        }

        stopTimesText.enumerateLines { line, _ in
            // GTFS stop_times fields are identifiers, times and numeric flags;
            // they contain no free-text commas. This avoids slow Character-by-
            // Character parsing of the 16 MB file on a physical iPhone.
            let row = line.split(
                separator: ",",
                omittingEmptySubsequences: false
            ).map(String.init)

            if !hasReadHeader {
                let headers = self.normalizedHeaders(row)
                tripIDIndex = headers.firstIndex(of: "trip_id")
                stopIDIndex = headers.firstIndex(of: "stop_id")
                sequenceIndex = headers.firstIndex(of: "stop_sequence")
                departureTimeIndex = headers.firstIndex(of: "departure_time")
                pickupTypeIndex = headers.firstIndex(of: "pickup_type")
                hasReadHeader = true
                return
            }

            guard let tripIDIndex, let stopIDIndex else { return }
            let tripID = self.value(row, at: tripIDIndex)
            let stopID = self.value(row, at: stopIDIndex)
            if currentTripID != tripID {
                keepCurrentTripIfNeeded()
                currentTripID = tripID
                currentTrip = trips[tripID]
            }
            guard let trip = currentTrip, !stopID.isEmpty else { return }

            let sequence = Int(self.value(row, at: sequenceIndex)) ?? Int.max
            currentStops.append(StopSequence(
                stopID: stopID,
                name: stops[stopID] ?? stopID,
                sequence: sequence,
                directionID: trip.directionID,
                directionName: trip.headsign
            ))

            let pickupType = self.value(row, at: pickupTypeIndex)
            if pickupType != "1",
               let seconds = self.gtfsSeconds(self.value(row, at: departureTimeIndex)) {
                let calendar = self.parisCalendar
                let key = stopID + "|" + trip.routeID
                for serviceDate in activeServiceDates[trip.serviceID] ?? [] {
                    scheduledDepartures[key, default: []].append(
                        GTFSScheduledDeparture(
                            destination: trip.headsign,
                            dueAt: calendar.startOfDay(for: serviceDate).addingTimeInterval(seconds)
                        )
                    )
                }
            }
        }
        keepCurrentTripIfNeeded()

        let canonicalStops: [String: [T2CStop]] = bestTripByDirection.mapValues { canonical in
            var seenStops = Set<String>()
            return canonical.compactMap { stop -> T2CStop? in
                guard seenStops.insert(stop.stopID).inserted else { return nil }
                return T2CStop(
                    stopID: stop.stopID,
                    name: stop.name,
                    directionID: stop.directionID,
                    directionName: stop.directionName
                )
            }
        }
        return (
            stops: canonicalStops,
            departures: scheduledDepartures.mapValues { $0.sorted { $0.dueAt < $1.dueAt } }
        )
    }

    private func buildRouteStops(
        stopTimesText: String,
        trips: [String: TripInfo],
        stops: [String: String]
    ) -> [String: [T2CStop]] {

        let rows =
            parseCSV(
                stopTimesText
            )

        guard let firstRow =
                rows.first
        else {
            return [:]
        }

        let headers =
            normalizedHeaders(
                firstRow
            )

        guard
            let tripIDIndex =
                headers.firstIndex(
                    of: "trip_id"
                ),
            let stopIDIndex =
                headers.firstIndex(
                    of: "stop_id"
                )
        else {
            return [:]
        }

        let sequenceIndex =
            headers.firstIndex(
                of: "stop_sequence"
            )

        var collected:
            [
                String:
                [String: StopSequence]
            ] = [:]

        for row in rows.dropFirst() {

            let tripID =
                value(
                    row,
                    at: tripIDIndex
                )

            let stopID =
                value(
                    row,
                    at: stopIDIndex
                )

            guard
                let trip =
                    trips[tripID],
                !stopID.isEmpty
            else {
                continue
            }

            let sequence =
                Int(
                    value(
                        row,
                        at: sequenceIndex
                    )
                )
                ?? Int.max

            let key =
                makeDirectionKey(
                    routeID:
                        trip.routeID,
                    directionID:
                        trip.directionID,
                    directionName:
                        trip.headsign
                )

            let previous =
                collected[key]?[stopID]

            if previous == nil
                || sequence < previous!.sequence {

                collected[
                    key,
                    default: [:]
                ][stopID] =
                    StopSequence(
                        stopID: stopID,
                        name:
                            stops[stopID]
                            ?? stopID,
                        sequence:
                            sequence,
                        directionID:
                            trip.directionID,
                        directionName:
                            trip.headsign
                    )
            }
        }

        var result:
            [String: [T2CStop]] = [:]

        for (
            key,
            stopDictionary
        ) in collected {

            result[key] =
                stopDictionary
                    .values
                    .sorted {
                        $0.sequence
                            < $1.sequence
                    }
                    .map {

                        T2CStop(
                            stopID:
                                $0.stopID,
                            name:
                                $0.name,
                            directionID:
                                $0.directionID,
                            directionName:
                                $0.directionName
                        )
                    }
        }

        return result
    }

    // MARK: - Timetable helpers

    private func matchesLine(
        _ value: String?,
        line: T2CLine
    ) -> Bool {

        guard let value else {
            return false
        }

        let left =
            normalize(value)

        return left
            == normalize(
                line.routeID
            )
            || left
            == normalize(
                line.shortName
            )
    }

    private func parseT2CDate(
        _ value: String?
    ) -> Date? {

        guard
            let value,
            !value.isEmpty
        else {
            return nil
        }

        let formatter =
            DateFormatter()

        formatter.locale =
            Locale(
                identifier: "fr_FR"
            )

        formatter.timeZone =
            TimeZone(
                identifier:
                    "Europe/Paris"
            )

        formatter.dateFormat =
            "yyyy-MM-dd HH:mm:ss"

        return formatter.date(
            from: value
        )
    }

    private func cleanHTML(
        _ value: String
    ) -> String {

        value
            .replacingOccurrences(
                of: "<[^>]+>",
                with: " ",
                options:
                    .regularExpression
            )
            .replacingOccurrences(
                of: "&nbsp;",
                with: " "
            )
            .replacingOccurrences(
                of: "&amp;",
                with: "&"
            )
            .replacingOccurrences(
                of: "&#39;",
                with: "'"
            )
            .replacingOccurrences(
                of: "&quot;",
                with: "\""
            )
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options:
                    .regularExpression
            )
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )
    }

    nonisolated private func normalize(
        _ value: String
    ) -> String {

        value
            .folding(
                options: [
                    .diacriticInsensitive,
                    .caseInsensitive
                ],
                locale:
                    Locale(
                        identifier:
                            "fr_FR"
                    )
            )
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )
    }

    // MARK: - CSV

    nonisolated private func normalizedHeaders(
        _ row: [String]
    ) -> [String] {

        row.map {

            $0
                .replacingOccurrences(
                    of: "\u{feff}",
                    with: ""
                )
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
        }
    }

    nonisolated private func value(
        _ row: [String],
        at index: Int?
    ) -> String {

        guard
            let index,
            row.indices.contains(
                index
            )
        else {
            return ""
        }

        return row[index]
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )
    }

    nonisolated private func parseCSV(
        _ text: String
    ) -> [[String]] {

        var rows:
            [[String]] = []

        var row:
            [String] = []

        var field = ""

        var insideQuotes = false

        var index =
            text.startIndex

        while index < text.endIndex {

            let character =
                text[index]

            if character == "\"" {

                let nextIndex =
                    text.index(
                        after: index
                    )

                if insideQuotes,
                   nextIndex
                    < text.endIndex,
                   text[nextIndex]
                    == "\"" {

                    field.append("\"")

                    index =
                        nextIndex

                } else {

                    insideQuotes.toggle()
                }

            } else if character == ","
                        && !insideQuotes {

                row.append(field)

                field = ""

            } else if character == "\n"
                        && !insideQuotes {

                row.append(field)

                if !row.allSatisfy({
                    $0.isEmpty
                }) {
                    rows.append(row)
                }

                row = []

                field = ""

            } else if character != "\r" {

                field.append(
                    character
                )
            }

            index =
                text.index(
                    after: index
                )
        }

        if !field.isEmpty
            || !row.isEmpty {

            row.append(field)

            rows.append(row)
        }

        return rows
    }

    private func forEachCSVRow(
        in text: String,
        body: ([String]) -> Void
    ) {
        var row: [String] = []
        var field = ""
        var insideQuotes = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character == "\"" {
                let nextIndex = text.index(after: index)
                if insideQuotes,
                   nextIndex < text.endIndex,
                   text[nextIndex] == "\"" {
                    field.append("\"")
                    index = nextIndex
                } else {
                    insideQuotes.toggle()
                }
            } else if character == "," && !insideQuotes {
                row.append(field)
                field.removeAll(keepingCapacity: true)
            } else if character == "\n" && !insideQuotes {
                row.append(field)
                if !row.allSatisfy({ $0.isEmpty }) { body(row) }
                row.removeAll(keepingCapacity: true)
                field.removeAll(keepingCapacity: true)
            } else if character != "\r" {
                field.append(character)
            }

            index = text.index(after: index)
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            body(row)
        }
    }

    private func makeDirectionKey(
        routeID: String,
        directionID: String,
        directionName: String
    ) -> String {

        [
            routeID,
            directionID,
            normalize(
                directionName
            )
        ]
        .joined(
            separator: "|"
        )
    }
}

// MARK: - GTFS internes

private struct GTFSIndex {

    let stations: [NearbyStation]

    let lines: [T2CLine]

    let directionsByRoute:
        [String: [T2CDirection]]

    let stopsByDirection:
        [String: [T2CStop]]

    let scheduledDeparturesByStopAndRoute:
        [String: [GTFSScheduledDeparture]]
}

private struct TripInfo {

    let routeID: String
    let serviceID: String
    let shapeID: String
    let directionID: String
    let headsign: String
}

struct T2CShapePoint: Sendable, Hashable {
    let latitude: Double
    let longitude: Double
}

struct T2CLineShape: Identifiable, Sendable {
    let id: String
    let directionID: String
    let destination: String
    let points: [T2CShapePoint]
}

private struct GTFSScheduledDeparture {
    let destination: String
    let dueAt: Date
}

private struct StopSequence {

    let stopID: String
    let name: String

    let sequence: Int

    let directionID: String
    let directionName: String
}

private struct JourneyPattern {
    let lineID: String
    let direction: String
    let stationIDs: [String]
}

private struct JourneyCandidateLeg {
    let line: T2CLine
    let origin: NearbyStation
    let destination: NearbyStation
    let stations: [NearbyStation]
    let direction: String
    let stopCount: Int
    let walkBefore: T2CWalkingSegment?
}

private struct JourneyDepartureCache {
    let loadedAt: Date
    let departures: [T2CDeparture]
}

// MARK: - Dataset

private struct DatasetMetadata: Decodable {

    let resources:
        [DatasetResource]
}

private struct DatasetResource: Decodable {

    let title: String?
    let format: String?
    let mime: String?
    let type: String?

    let latest: String?
    let url: String?
}

// MARK: - API QR T2C

private struct RawTimetableResponse: Decodable {

    let timetable:
        RawTimetableContainer?

    let message:
        [RawInfoMessage]?

    let referentialLine:
        [RawReferentialLine]?

    enum CodingKeys: String, CodingKey {
        case timetable
        case message
        case referentialLine = "referential_line"
    }
}

private struct RawReferentialLine: Decodable {
    let lineID: String
    let shortName: String

    enum CodingKeys: String, CodingKey {
        case lineID = "line_id"
        case shortName = "short_name"
    }
}

private struct RawTimetableContainer: Decodable {

    let timetable:
        [RawDeparture]?
}

private struct RawDeparture: Decodable {

    let datetime: String?
    let datetimeEstimated: String?

    let departureStatus: String?

    let theoretical: Bool?

    let info: String?

    let lineID: String?

    let destination: String?

    enum CodingKeys:
        String,
        CodingKey {

        case datetime

        case datetimeEstimated =
            "datetime_estimated"

        case departureStatus =
            "departure_status"

        case theoretical =
            "theorique"

        case info

        case lineID =
            "line_id"

        case destination
    }

    init(
        from decoder: Decoder
    ) throws {

        let container =
            try decoder.container(
                keyedBy:
                    CodingKeys.self
            )

        datetime =
            try? container.decode(
                String.self,
                forKey:
                    .datetime
            )

        datetimeEstimated =
            try? container.decode(
                String.self,
                forKey:
                    .datetimeEstimated
            )

        departureStatus =
            try? container.decode(
                String.self,
                forKey:
                    .departureStatus
            )

        info =
            try? container.decode(
                String.self,
                forKey:
                    .info
            )

        destination =
            try? container.decode(
                String.self,
                forKey:
                    .destination
            )

        if let string =
            try? container.decode(
                String.self,
                forKey:
                    .lineID
            ) {

            lineID = string

        } else if let int =
            try? container.decode(
                Int.self,
                forKey:
                    .lineID
            ) {

            lineID =
                String(int)

        } else {

            lineID = nil
        }

        if let bool =
            try? container.decode(
                Bool.self,
                forKey:
                    .theoretical
            ) {

            theoretical = bool

        } else if let int =
            try? container.decode(
                Int.self,
                forKey:
                    .theoretical
            ) {

            theoretical =
                int != 0

        } else if let string =
            try? container.decode(
                String.self,
                forKey:
                    .theoretical
            ) {

            theoretical =
                ["true", "1", "oui"]
                    .contains(
                        string.lowercased()
                    )

        } else {

            theoretical = nil
        }
    }
}

private struct RawInfoMessage:
    Decodable {

    let id: String?

    let title: String?
    let content: String?

    let validStartTime: String?
    let validUntilTime: String?

    let lineRefs: [String]?
    let stopRefs: [String]?

    enum CodingKeys:
        String,
        CodingKey {

        case id
        case title
        case content

        case validStartTime =
            "valid_start_time"

        case validUntilTime =
            "valid_until_time"

        case lineRefs =
            "list_line_ref"

        case stopRefs =
            "list_stop_point_ref"
    }

    init(
        from decoder: Decoder
    ) throws {

        let container =
            try decoder.container(
                keyedBy:
                    CodingKeys.self
            )

        if let value =
            try? container.decode(
                String.self,
                forKey: .id
            ) {

            id = value

        } else if let value =
            try? container.decode(
                Int.self,
                forKey: .id
            ) {

            id =
                String(value)

        } else {

            id = nil
        }

        title =
            try? container.decode(
                String.self,
                forKey:
                    .title
            )

        content =
            try? container.decode(
                String.self,
                forKey:
                    .content
            )

        validStartTime =
            try? container.decode(
                String.self,
                forKey:
                    .validStartTime
            )

        validUntilTime =
            try? container.decode(
                String.self,
                forKey:
                    .validUntilTime
            )

        lineRefs =
            (
                try? container.decode(
                    [String].self,
                    forKey:
                        .lineRefs
                )
            )
            ?? []

        stopRefs =
            (
                try? container.decode(
                    [String].self,
                    forKey:
                        .stopRefs
                )
            )
            ?? []
    }
}

// MARK: - Erreurs

enum T2CServiceError:
    LocalizedError {

    case invalidURL

    case invalidResponse

    case gtfsNotFound

    case gtfsFileNotFound(
        String
    )

    case invalidGTFS

    var errorDescription:
        String? {

        switch self {

        case .invalidURL:

            return "Adresse T2C invalide."

        case .invalidResponse:

            return "Le serveur T2C n'a pas répondu correctement."

        case .gtfsNotFound:

            return "Impossible de trouver les données GTFS T2C."

        case .gtfsFileNotFound(
            let filename
        ):

            return "Le fichier \(filename) est introuvable dans le GTFS."

        case .invalidGTFS:

            return "Les données GTFS T2C sont invalides."
        }
    }
}
