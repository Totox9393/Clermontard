//
//  T2CModels.swift
//  Clermontard
//

import Foundation
import CoreLocation

// MARK: - Recherche d'arrêts

enum StationSearch {
    private static let tokenAliases: [String: [String]] = [
        "pl": ["place"],
        "av": ["avenue"],
        "rte": ["route"],
        "st": ["saint"],
        "ste": ["sainte"],
        "dr": ["docteur"],
        "chu": ["centre", "hospitalier", "hopital"],
        "uca": ["universite", "clermont", "auvergne"],
        "zi": ["zone", "industrielle"],
        "rn": ["route", "nationale"],
        "fac": ["faculte"]
    ]

    private static let nameAliases: [(abbreviated: String, expanded: String)] = [
        ("g montpied", "gabriel montpied"),
        ("m michelin", "marcel michelin"),
        ("p marcombes", "philippe marcombes"),
        ("l michel", "louise michel"),
        ("j ferry", "jules ferry"),
        ("a camus", "albert camus"),
        ("a brugiere", "ambroise brugiere"),
        ("m boubat", "marcel boubat"),
        ("v g e", "valery giscard estaing")
    ]

    static func matches(_ stationName: String, query: String) -> Bool {
        let searchedTokens = normalizedTokens(query)
        guard !searchedTokens.isEmpty else { return true }

        let stationTokens = searchableTokens(stationName)
        return searchedTokens.allSatisfy { searched in
            stationTokens.contains { candidate in
                candidate == searched || (searched.count >= 4 && candidate.hasPrefix(searched))
            }
        }
    }

    private static func searchableTokens(_ stationName: String) -> [String] {
        let normalizedName = normalize(stationName)
        let originalTokens = normalizedName.split(separator: " ").map(String.init)
        var tokens = originalTokens

        for token in originalTokens {
            tokens.append(contentsOf: tokenAliases[token] ?? [])
        }
        for alias in nameAliases where containsPhrase(normalizedName, alias.abbreviated) {
            tokens.append(contentsOf: alias.expanded.split(separator: " ").map(String.init))
        }
        return tokens
    }

    private static func normalizedTokens(_ value: String) -> [String] {
        normalize(value).split(separator: " ").map(String.init)
    }

    private static func containsPhrase(_ value: String, _ phrase: String) -> Bool {
        " \(value) ".contains(" \(phrase) ")
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let words = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(words).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Ligne

struct T2CLine: Identifiable, Hashable, Sendable {

    let routeID: String
    let shortName: String
    let longName: String
    let colorHex: String
    let textColorHex: String
    var routeType: Int = 3

    var isTram: Bool { routeType == 0 || routeType == 900 }

    var id: String {
        routeID
    }
}

// MARK: - Direction

struct T2CDirection: Identifiable, Hashable, Sendable {

    let directionID: String
    let name: String

    var id: String {
        "\(directionID)|\(name)"
    }
}

// MARK: - Arrêt

struct T2CStop: Identifiable, Hashable, Sendable {

    let stopID: String
    let name: String
    let directionID: String?
    let directionName: String?

    var id: String {
        "\(stopID)|\(directionID ?? "")|\(directionName ?? "")"
    }
}

// MARK: - Passage

struct T2CDeparture: Identifiable, Hashable, Sendable {

    let routeID: String?
    let routeName: String?
    let stopID: String

    let destination: String?

    let dueAt: Date
    let scheduledAt: Date?
    let estimatedAt: Date?

    let status: String?
    let theoretical: Bool?

    let info: String?

    var id: String {
        [
            routeID ?? "",
            stopID,
            destination ?? "",
            String(dueAt.timeIntervalSince1970)
        ].joined(separator: "|")
    }

    var isCancelled: Bool {

        let value = status?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return value == "cancelled"
            || value == "canceled"
            || value == "annule"
            || value == "annulé"
    }

    var isRealtime: Bool {

        guard !isCancelled else {
            return false
        }

        return estimatedAt != nil
            && theoretical != true
    }
}

// MARK: - Message arrêt

struct T2CInfoMessage: Identifiable, Hashable, Sendable {

    let messageID: String
    let title: String
    let content: String

    let validFrom: String?
    let validUntil: String?

    let lineRefs: [String]
    let stopRefs: [String]

    var id: String {
        messageID.isEmpty
            ? "\(title)|\(content)"
            : messageID
    }
}

// MARK: - Résultat horaires

struct T2CTimetableResult: Sendable {

    let realtimeDepartures: [T2CDeparture]
    let theoreticalDepartures: [T2CDeparture]
    let cancelledDepartures: [T2CDeparture]

    let messages: [T2CInfoMessage]
}

// MARK: - Perturbation

struct T2CAlert: Identifiable, Decodable, Sendable {

    let id: String

    let type: String
    let title: String
    let text: String

    let startDatetime: String?
    let endDatetime: String?

    let priority: Int?
    let affectedRoutes: [String]
    let disruptionLevel: String?

    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {

        case id
        case type
        case title
        case text

        case startDatetime = "start_datetime"
        case endDatetime = "end_datetime"

        case priority

        case affectedRoutes = "affected_routes"
        case disruptionLevel = "disruption_level"

        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {

        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )

        self.id =
            container.decodeFlexibleString(
                forKey: .id
            )
            ?? UUID().uuidString

        self.type =
            (try? container.decode(
                String.self,
                forKey: .type
            ))
            ?? ""

        self.title =
            (try? container.decode(
                String.self,
                forKey: .title
            ))
            ?? "Information T2C"

        let rawText =
            (try? container.decode(
                String.self,
                forKey: .text
            ))
            ?? ""

        self.text = rawText
            .replacingOccurrences(
                of: "<[^>]+>",
                with: " ",
                options: .regularExpression
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
                of: "&quot;",
                with: "\""
            )
            .replacingOccurrences(
                of: "&#39;",
                with: "'"
            )
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        self.startDatetime =
            try? container.decode(
                String.self,
                forKey: .startDatetime
            )

        self.endDatetime =
            try? container.decode(
                String.self,
                forKey: .endDatetime
            )

        self.priority =
            container.decodeFlexibleInt(
                forKey: .priority
            )

        self.affectedRoutes =
            container.decodeFlexibleStringArray(
                forKey: .affectedRoutes
            )

        self.disruptionLevel =
            try? container.decode(
                String.self,
                forKey: .disruptionLevel
            )

        self.createdAt =
            try? container.decode(
                String.self,
                forKey: .createdAt
            )

        self.updatedAt =
            try? container.decode(
                String.self,
                forKey: .updatedAt
            )
    }
}

// MARK: - Helpers Codable

private extension KeyedDecodingContainer {

    func decodeFlexibleString(
        forKey key: Key
    ) -> String? {

        if let value = try? decode(
            String.self,
            forKey: key
        ) {
            return value
        }

        if let value = try? decode(
            Int.self,
            forKey: key
        ) {
            return String(value)
        }

        if let value = try? decode(
            Double.self,
            forKey: key
        ) {
            return String(value)
        }

        return nil
    }

    func decodeFlexibleInt(
        forKey key: Key
    ) -> Int? {

        if let value = try? decode(
            Int.self,
            forKey: key
        ) {
            return value
        }

        if let value = try? decode(
            String.self,
            forKey: key
        ) {
            return Int(value)
        }

        return nil
    }

    func decodeFlexibleStringArray(
        forKey key: Key
    ) -> [String] {

        if let values = try? decode(
            [String].self,
            forKey: key
        ) {
            return values
        }

        if let values = try? decode(
            [Int].self,
            forKey: key
        ) {
            return values.map(String.init)
        }

        return []
    }
}

// A station groups nearby platforms, while retaining their individual timetable codes.
struct NearbyStation: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var platforms: [StationPlatform]
    var lines: [T2CLine]
}

struct StationPlatform: Identifiable, Hashable, Sendable {
    let id: String
    let latitude: Double?
    let longitude: Double?
    let routeIDs: Set<String>
}

// MARK: - Itinéraires

struct T2CJourney: Identifiable, Hashable, Sendable {
    let id: String
    let legs: [T2CJourneyLeg]
    let departureAt: Date
    let arrivalAt: Date
    let directWalk: T2CWalkingSegment?

    var duration: TimeInterval { arrivalAt.timeIntervalSince(departureAt) }
    var transferCount: Int { max(legs.count - 1, 0) }
    var usesRealtime: Bool { legs.contains(where: \.isRealtime) }
    var walkingDuration: TimeInterval {
        directWalk?.duration ?? legs.compactMap(\.walkBefore).reduce(0) { $0 + $1.duration }
    }
}

struct T2CWalkingSegment: Hashable, Sendable {
    let origin: NearbyStation
    let destination: NearbyStation
    let distance: CLLocationDistance
    let duration: TimeInterval
}

struct T2CJourneyLeg: Identifiable, Hashable, Sendable {
    let id: String
    let line: T2CLine
    let origin: NearbyStation
    let destination: NearbyStation
    let stations: [NearbyStation]
    let direction: String
    let stopCount: Int
    let departureAt: Date
    let arrivalAt: Date
    let isRealtime: Bool
    let transferBuffer: TimeInterval?
    let walkBefore: T2CWalkingSegment?
}
