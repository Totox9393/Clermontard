import SwiftUI

struct TimetablesView: View {
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
        count: 4
    )

    @State private var lines: [T2CLine] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?
    @StateObject private var favorites = FavoritesStore.shared

    private var visibleLines: [T2CLine] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = value.isEmpty ? lines : lines.filter {
            $0.shortName.localizedStandardContains(value) || $0.longName.localizedStandardContains(value)
        }
        return filtered.sorted {
            let a = favorites.isLineFavorite($0), b = favorites.isLineFavorite($1)
            return a == b ? $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending : a
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    SearchField(placeholder: "Rechercher une ligne", text: $query)
                    if loading && lines.isEmpty { ProgressView("Chargement des lignes…") }
                    if let error {
                        Text(error).foregroundStyle(.secondary)
                        Button("Réessayer") { Task { await load() } }
                    }
                    if !loading && error == nil && visibleLines.isEmpty {
                        ContentUnavailableView("Aucune ligne trouvée", systemImage: "magnifyingglass", description: Text("Essayez un autre nom ou numéro."))
                    }
                    ForEach(["Favoris", "Tram et lignes principales", "Essentielles", "Structurantes", "Proximité", "Autres lignes"], id: \.self) { category in
                        let group = visibleLines.filter { categoryFor($0) == category }
                        if !group.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(category).font(.headline)
                                LazyVGrid(columns: columns, spacing: 18) {
                                    ForEach(group) { line in
                                        NavigationLink { LineDetailView(line: line) } label: {
                                            LineBadgeView(line: line, size: 64)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 12)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button {
                                                favorites.toggle(line: line)
                                            } label: {
                                                Label(
                                                    favorites.isLineFavorite(line)
                                                        ? "Retirer des favoris"
                                                        : "Ajouter aux favoris",
                                                    systemImage: favorites.isLineFavorite(line)
                                                        ? "star.slash"
                                                        : "star"
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }.padding(24).frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
            .navigationTitle("Horaires")
            .background(Color(uiColor: .systemBackground))
            .scrollDismissesKeyboard(.interactively)
            .task { if lines.isEmpty { await load() } }
            .refreshable { await load() }
        }
    }

    private func categoryFor(_ line: T2CLine) -> String {
        if favorites.isLineFavorite(line) { return "Favoris" }
        if ["A", "B", "C"].contains(line.shortName) { return "Tram et lignes principales" }
        if line.shortName.hasPrefix("E") { return "Essentielles" }
        if line.shortName.hasPrefix("S") { return "Structurantes" }
        if line.shortName.hasPrefix("P") { return "Proximité" }
        return "Autres lignes"
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { lines = try await T2CService.shared.getLines() }
        catch { self.error = "Impossible de charger les lignes. Vérifiez votre connexion." }
    }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("Effacer la recherche")
            }
        }.padding(16)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview { TimetablesView() }
