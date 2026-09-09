import SwiftUI

/// One compact row; long descriptions are available on demand.
struct TrafficSummaryView: View {
    let alerts: [T2CAlert]
    var messages: [T2CInfoMessage] = []
    var unavailable = false
    var loading = false
    @State private var expanded = false

    private var count: Int { alerts.count + messages.count }
    private var title: String {
        if loading && count == 0 { return "Vérification du trafic…" }
        if unavailable && count == 0 { return "Informations trafic indisponibles" }
        return count == 0 ? "Aucune perturbation signalée" : "\(count) information\(count > 1 ? "s" : "") trafic"
    }
    var body: some View {
        Button { expanded = true } label: {
            HStack(spacing: 12) {
                Image(systemName: count > 0 ? "exclamationmark.triangle.fill" : unavailable ? "wifi.exclamationmark" : "checkmark.circle")
                    .foregroundStyle(count > 0 ? Color.orange : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    if count > 0 {
                        Text(alerts.first?.title ?? messages.first?.title ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if count > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 14).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(count == 0)
        .sheet(isPresented: $expanded) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if unavailable { Text("L’actualisation a échoué. Les dernières informations reçues sont affichées.").font(.footnote).foregroundStyle(.secondary) }
                        ForEach(alerts) { alert in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(alert.title).font(.headline)
                                if !alert.text.isEmpty { Text(alert.text).font(.subheadline).foregroundStyle(.secondary) }
                            }
                            Divider()
                        }
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(message.title).font(.headline)
                                Text(message.content).font(.subheadline).foregroundStyle(.secondary)
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
    }
}
