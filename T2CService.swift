//
//  T2CService.swift
//  Clermontard
//

import Foundation
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

    // MARK: - Lignes

    func getLines() async throws -> [T2CLine] {

        let gtfs = try await getGTFSIndex()

        return gtfs.lines
    }

    func getStations() async throws -> [NearbyStation] {
        try await getGTFSIndex().stations
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

        var realtime: [T2CDeparture] = []
        var theoretical: [T2CDeparture] = []
        var cancelled: [T2CDeparture] = []

        for raw in rawDepartures {

            guard matchesLine(
                raw.lineID,
                line: line
            ) else {
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

        let routeStops =
            buildRouteStopsStreaming(
                stopTimesText: stopTimesText,
                trips: trips,
                stops: stops
            )

        return GTFSIndex(
            stations: buildStations(text: stopsText, lines: lines, directions: directions, routeStops: routeStops),
            lines: lines,
            directionsByRoute:
                directions,
            stopsByDirection:
                routeStops
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

    private func extractText(
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

    private func parseTripsCSV(
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
                    directionID:
                        directionID,
                    headsign:
                        headsign
                )
        }

        return result
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
        stops: [String: String]
    ) -> [String: [T2CStop]] {
        var tripIDIndex: Int?
        var stopIDIndex: Int?
        var sequenceIndex: Int?
        var hasReadHeader = false
        var collected: [String: [String: StopSequence]] = [:]

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
                hasReadHeader = true
                return
            }

            guard let tripIDIndex, let stopIDIndex else { return }
            let tripID = self.value(row, at: tripIDIndex)
            let stopID = self.value(row, at: stopIDIndex)
            guard let trip = trips[tripID], !stopID.isEmpty else { return }

            let sequence = Int(self.value(row, at: sequenceIndex)) ?? Int.max
            let key = self.makeDirectionKey(
                routeID: trip.routeID,
                directionID: trip.directionID,
                directionName: trip.headsign
            )
            let previous = collected[key]?[stopID]
            guard previous == nil || sequence < previous!.sequence else { return }

            collected[key, default: [:]][stopID] = StopSequence(
                stopID: stopID,
                name: stops[stopID] ?? stopID,
                sequence: sequence,
                directionID: trip.directionID,
                directionName: trip.headsign
            )
        }

        return collected.mapValues { stopDictionary in
            stopDictionary.values
                .sorted { $0.sequence < $1.sequence }
                .map {
                    T2CStop(
                        stopID: $0.stopID,
                        name: $0.name,
                        directionID: $0.directionID,
                        directionName: $0.directionName
                    )
                }
        }
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

    private func normalize(
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

    private func normalizedHeaders(
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

    private func value(
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

    private func parseCSV(
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
}

private struct TripInfo {

    let routeID: String
    let directionID: String
    let headsign: String
}

private struct StopSequence {

    let stopID: String
    let name: String

    let sequence: Int

    let directionID: String
    let directionName: String
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
