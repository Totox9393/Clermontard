import SwiftUI

/// Informations T2C compactes affichées sur la page d'une ligne.
struct TrafficSummaryView: View {
    let alerts: [T2CAlert]
    var messages: [T2CInfoMessage] = []
    var unavailable = false
    var loading = false

    @State private var expanded = false
    @State private var selectedID = ""

    private var items: [TrafficItem] {
        alerts.map {
            TrafficItem(
                id: "alert-\($0.id)",
                title: category(for: $0),
                text: $0.text.isEmpty ? $0.title : $0.text,
                disruptive: true
            )
        } + messages.compactMap {
            let text = $0.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TrafficItem(id: "message-\($0.id)", title: $0.title, text: text, disruptive: false)
        }
    }

    var body: some View {
        if items.isEmpty {
            HStack(spacing: 10) {
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Vérification du trafic…")
                } else {
                    Image(systemName: unavailable ? "wifi.exclamationmark" : "checkmark.circle")
                    Text(unavailable ? "Informations trafic indisponibles" : "Aucune perturbation signalée")
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        } else {
            VStack(spacing: 7) {
                TabView(selection: $selectedID) {
                    ForEach(items) { item in
                        Button { expanded = true } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 8) {
                                Image(systemName: item.disruptive ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                Text(item.title).font(.caption.weight(.bold))
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            Text(item.text)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(item.disruptive ? Color.red : Color.secondary)
                        .padding(14)
                        .background((item.disruptive ? Color.red : Color.secondary).opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .tag(item.id)
                    }
                }
                .frame(height: 106)
                .tabViewStyle(.page(indexDisplayMode: .never))

                if items.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(items) { item in
                            Button { withAnimation(.easeInOut) { selectedID = item.id } } label: {
                                Circle()
                                    .fill(Color.primary.opacity(selectedID == item.id ? 0.75 : 0.22))
                                    .frame(width: selectedID == item.id ? 7 : 6, height: selectedID == item.id ? 7 : 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .onAppear { selectFirstIfNeeded() }
            .onChange(of: items.map(\.id)) { _, _ in selectFirstIfNeeded() }
            .task(id: selectedID) {
                guard items.count > 1 else { return }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                let ids = items.map(\.id)
                let current = ids.firstIndex(of: selectedID) ?? 0
                withAnimation(.easeInOut) { selectedID = ids[(current + 1) % ids.count] }
            }
            .sheet(isPresented: $expanded) { details }
        }
    }

    private var details: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if unavailable {
                        Text("L’actualisation a échoué. Les dernières informations reçues sont affichées.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(.headline)
                            Text(item.text).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }.padding(24)
            }
            .navigationTitle("Informations trafic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { expanded = false } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func category(for alert: T2CAlert) -> String {
        let value = "\(alert.title) \(alert.text) \(alert.disruptionLevel ?? "")"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if value.contains("accident") { return "Accident" }
        if value.contains("incident technique") || value.contains("panne") { return "Incident technique" }
        if value.contains("travaux") { return "Travaux" }
        if value.contains("deviation") { return "Déviation" }
        if value.contains("retard") { return "Retard" }
        return "Perturbation"
    }

    private func selectFirstIfNeeded() {
        let ids = items.map(\.id)
        if !ids.contains(selectedID) { selectedID = ids.first ?? "" }
    }
}

private struct TrafficItem: Identifiable {
    let id: String
    let title: String
    let text: String
    let disruptive: Bool
}
