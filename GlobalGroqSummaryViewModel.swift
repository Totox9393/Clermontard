import Foundation
import Combine

struct GlobalTrafficSummary: Identifiable, Sendable {
    let id: String
    let resume: String
    let category: String
    let affectedRoutes: [String]
}

@MainActor
final class GlobalGroqSummaryViewModel: ObservableObject {
    @Published var summaries: [GlobalTrafficSummary] = []
    @Published var isLoading = false
    private var lastAlertsFingerprint: String?
    private var previousSummaries: [String: GlobalTrafficSummary] = [:]
    private var resolvedUntil: Date?

    func summarize(alerts: [T2CAlert]) async {
        let usefulAlerts = alerts.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let fingerprint = usefulAlerts
            .map { "\($0.id)|\($0.updatedAt ?? "")|\($0.title)|\($0.text)" }
            .sorted()
            .joined(separator: "\n")

        guard !usefulAlerts.isEmpty else {
            if lastAlertsFingerprint != nil {
                if !previousSummaries.isEmpty {
                    summaries = previousSummaries.values.map {
                        GlobalTrafficSummary(
                            id: "resolved-\($0.id)",
                            resume: resolvedText(for: $0),
                            category: "Circulation rétablie",
                            affectedRoutes: $0.affectedRoutes
                        )
                    }
                    resolvedUntil = Date().addingTimeInterval(10 * 60)
                    previousSummaries = [:]
                } else if resolvedUntil.map({ $0 <= Date() }) == true {
                    summaries = []
                    resolvedUntil = nil
                }
            } else {
                summaries = []
            }
            lastAlertsFingerprint = fingerprint
            isLoading = false
            return
        }
        if fingerprint == lastAlertsFingerprint { return }

        isLoading = true
        resolvedUntil = nil
        var newSummaries: [GlobalTrafficSummary] = []
        for alert in usefulAlerts {
            guard !Task.isCancelled else { break }
            let source = [alert.title, alert.text]
                .filter { !$0.isEmpty }
                .joined(separator: ". ")
            let result: GroqSummary?
            if shouldUseGroq(for: source) {
                result = await GroqAPI.shared.summarize(alerts: [source])
            } else {
                result = nil
            }
            let directText = alert.text.isEmpty ? alert.title : alert.text
            let resume = (result?.resume ?? directText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resume.isEmpty,
                  !resume.localizedCaseInsensitiveContains("aucun message") else { continue }
            let rawCategory = (result?.category ?? category(for: alert))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let category = rawCategory.isEmpty
                || rawCategory.localizedCaseInsensitiveContains("inconnu")
                ? "Information réseau"
                : rawCategory
            newSummaries.append(
                GlobalTrafficSummary(
                    id: alert.id,
                    resume: resume,
                    category: category,
                    affectedRoutes: alert.affectedRoutes
                )
            )
        }
        let currentIDs = Set(newSummaries.map(\.id))
        let resolved = previousSummaries.values
            .filter { !currentIDs.contains($0.id) }
            .map {
                GlobalTrafficSummary(
                    id: "resolved-\($0.id)",
                    resume: resolvedText(for: $0),
                    category: "Circulation rétablie",
                    affectedRoutes: $0.affectedRoutes
                )
            }
        summaries = newSummaries + resolved
        previousSummaries = Dictionary(uniqueKeysWithValues: newSummaries.map { ($0.id, $0) })
        lastAlertsFingerprint = fingerprint
        isLoading = false
    }

    private func shouldUseGroq(for text: String) -> Bool {
        text.count > 220
            || text.contains("http://")
            || text.contains("https://")
            || text.components(separatedBy: ". ").count > 4
    }

    private func category(for alert: T2CAlert) -> String {
        let value = "\(alert.title) \(alert.text) \(alert.disruptionLevel ?? "")"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if value.contains("retabli") || value.contains("reprise") { return "Circulation rétablie" }
        if value.contains("accident") { return "Accident" }
        if value.contains("incident technique") || value.contains("panne") { return "Incident technique" }
        if value.contains("interromp") || value.contains("ne circule pas") { return "Perturbation" }
        if value.contains("travaux") { return "Travaux" }
        if value.contains("deviation") { return "Déviation" }
        if value.contains("greve") || value.contains("mouvement social") { return "Mouvement social" }
        if value.contains("retard") { return "Retard" }
        let title = alert.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Information réseau" : title
    }

    private func resolvedText(for summary: GlobalTrafficSummary) -> String {
        guard !summary.affectedRoutes.isEmpty else {
            return "La perturbation signalée sur le réseau T2C est terminée."
        }
        return "La circulation est rétablie sur la ligne \(summary.affectedRoutes.joined(separator: ", "))."
    }
}
