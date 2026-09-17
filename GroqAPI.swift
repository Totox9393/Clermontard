import Foundation

struct GroqSummary: Sendable {
    let resume: String
    let category: String
    let provenance: String // "Groq" ou "Fallback"
}

enum GroqAPIError: Error {
    case missingAPIKey
    case invalidResponse
    case requestFailed(Error)
}

actor GroqAPI {
    static let shared = GroqAPI()
    private let endpoint = "https://api.groq.com/openai/v1/chat/completions"
    private var apiKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GROQ_API_KEY") as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    func summarize(alerts: [String]) async -> GroqSummary {
        let alerts = alerts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !alerts.isEmpty else {
            return GroqSummary(resume: "", category: "", provenance: "Empty")
        }
        print("[GroqAPI] Configuration de la clé:", apiKey == nil ? "absente" : "présente")
        guard let apiKey, !apiKey.isEmpty else {
            print("[Groq Fallback] Clé API manquante ou vide.")
            print("[Groq Fallback] Alerte(s):", alerts)
            return fallbackSummary(alerts: alerts)
        }
        let prompt = """
        Voici des messages d’alertes transports :
        - \(alerts.joined(separator: "\n- "))
        Résume-les en une seule phrase courte compréhensible pour un voyageur. Classe-les dans l’une des catégories suivantes : accident, grève, service interrompu travaux, déviation, arrêt non desservi, retard. Retourne le résultat sous la forme JSON : { \"resume\": ..., \"category\": ... }"
        """

        let requestBody: [String: Any] = [
            "model": "openai/gpt-oss-20b",
            "messages": [
                ["role": "system", "content": "Réponds uniquement avec un objet JSON valide contenant resume et category."],
                ["role": "user", "content": prompt]
            ],
            "response_format": ["type": "json_object"],
            "reasoning_effort": "low",
            "temperature": 0.2,
            "max_tokens": 240
        ]
        guard let url = URL(string: endpoint) else {
            print("[Groq Fallback] URL invalide :", endpoint)
            print("[Groq Fallback] Alerte(s):", alerts)
            return fallbackSummary(alerts: alerts)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[GroqAPI] Erreur HTTP:", status)
                return fallbackSummary(alerts: alerts)
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[GroqAPI] Erreur: réponse brute non JSON ou JSON invalide")
                print("[GroqAPI] Contenu reçu:", String(data: data, encoding: .utf8) ?? "<pas de texte>")
                print("[Groq Fallback] Alerte(s):", alerts)
                return fallbackSummary(alerts: alerts)
            }
            guard let choices = json["choices"] as? [[String: Any]], !choices.isEmpty else {
                print("[GroqAPI] Erreur: champ 'choices' manquant ou vide dans la réponse JSON")
                print("[GroqAPI] Contenu reçu:", String(data: data, encoding: .utf8) ?? "<pas de texte>")
                print("[Groq Fallback] Alerte(s):", alerts)
                return fallbackSummary(alerts: alerts)
            }
            guard let message = choices.first?["message"] as? [String: Any] else {
                print("[GroqAPI] Erreur: champ 'message' manquant dans 'choices[0]'")
                print("[GroqAPI] Contenu reçu:", String(data: data, encoding: .utf8) ?? "<pas de texte>")
                print("[Groq Fallback] Alerte(s):", alerts)
                return fallbackSummary(alerts: alerts)
            }
            guard let content = message["content"] as? String else {
                print("[GroqAPI] Erreur: champ 'content' manquant dans 'message'")
                print("[GroqAPI] Contenu reçu:", String(data: data, encoding: .utf8) ?? "<pas de texte>")
                print("[Groq Fallback] Alerte(s):", alerts)
                return fallbackSummary(alerts: alerts)
            }
            guard let parsed = try? JSONDecoder().decode(GroqSummaryResponse.self, from: Data(content.utf8)) else {
                print("[GroqAPI] Erreur: JSON 'content' non parsable")
                print("[GroqAPI] Contenu 'content':", content)
                print("[Groq Fallback] Alerte(s):", alerts)
                return fallbackSummary(alerts: alerts)
            }
            return GroqSummary(resume: parsed.resume, category: parsed.category, provenance: "Groq")
        } catch {
            print("[GroqAPI] Erreur réseau ou parsing:", error)
        }
        print("[Groq Fallback] Alerte(s):", alerts)
        return fallbackSummary(alerts: alerts)
    }

    /// Groq ne reçoit que des parcours déjà réalisables et ne peut retourner
    /// qu'un identifiant de cette liste. `nil` laisse le classement local agir.
    func recommendJourney(from journeys: [T2CJourney], requestedDeparture: Date) async -> String? {
        guard let apiKey, journeys.count > 1 else { return nil }
        let candidates = journeys.prefix(10).map { journey -> [String: Any] in
            let waits = journey.legs.compactMap(\.transferBuffer).map { max(Int($0 / 60), 0) }
            return [
                "id": journey.id,
                "depart": journey.departureAt.ISO8601Format(),
                "arrivee": journey.arrivalAt.ISO8601Format(),
                "duree_porte_a_porte_min": max(Int(journey.arrivalAt.timeIntervalSince(requestedDeparture) / 60), 0),
                "marche_min": Int(journey.walkingDuration / 60),
                "changements": journey.transferCount,
                "attentes_min": waits,
                "lignes": journey.legs.map(\.line.shortName),
                "marche_seule": journey.directWalk != nil
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: candidates),
              let encoded = String(data: data, encoding: .utf8) else { return nil }
        let prompt = """
        Choisis le meilleur itinéraire voyageur parmi cette liste VALIDÉE : \(encoded)
        Priorité absolue à l'arrivée la plus tôt depuis l'heure demandée. Ensuite seulement : moins de changements, correspondances sûres et marche raisonnable. Évite tout détour et préfère la marche seule si elle arrive nettement avant les transports. Retourne uniquement {"chosen_id":"..."} avec un identifiant fourni.
        """
        let body: [String: Any] = [
            "model": "openai/gpt-oss-20b",
            "messages": [
                ["role": "system", "content": "Tu classes des itinéraires T2C déjà calculés. Tu ne modifies aucune donnée et réponds uniquement en JSON."],
                ["role": "user", "content": prompt]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0,
            "max_tokens": 100
        ]
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let answer = try? JSONDecoder().decode(GroqJourneyChoice.self, from: contentData),
              journeys.contains(where: { $0.id == answer.chosenID }) else { return nil }
        return answer.chosenID
    }

    private func fallbackSummary(alerts: [String]) -> GroqSummary {
        let text = alerts.joined(separator: "\n\n")
        print("[Groq Fallback] Alerte(s):", alerts)
        return GroqSummary(resume: text, category: "Perturbation", provenance: "Fallback")
    }
}
private struct GroqJourneyChoice: Decodable {
    let chosenID: String
    enum CodingKeys: String, CodingKey { case chosenID = "chosen_id" }
}
private struct GroqSummaryResponse: Decodable {
    let resume: String
    let category: String
}
