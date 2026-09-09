import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var query = ""
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    BrandHeader().padding(.top, 20).padding(.bottom, 16)
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Partir de…")
                            .font(.system(size: 32, weight: .bold)).tracking(-1)
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Rechercher un arrêt", text: $query)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                            if !query.isEmpty {
                                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .accessibilityLabel("Effacer la recherche")
                            }
                        }
                        .padding(.vertical, 16).padding(.horizontal, 16)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        if viewModel.isLoading && viewModel.stations.isEmpty {
                            ProgressView("Chargement des arrêts T2C…").padding(.vertical)
                        } else if let error = viewModel.errorMessage {
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                            Button("Réessayer") { Task { await viewModel.load() } }
                        } else {
                            stationResults
                        }
                    }
                    TrafficSummaryView(alerts: viewModel.globalAlerts, unavailable: viewModel.trafficUnavailable, loading: viewModel.isLoading)

                }
                .padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            .task { viewModel.locate(); await viewModel.load() }
            .onDisappear { viewModel.stopLocating() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { viewModel.locate() }
                else { viewModel.stopLocating() }
            }
            .refreshable { viewModel.locate(); await viewModel.load() }
        }
    }


    @ViewBuilder private var stationResults: some View {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let results = searching ? viewModel.search(query) : viewModel.nearest
        VStack(alignment: .leading, spacing: 6) {
            Text(searching ? "\(results.count) arrêt\(results.count == 1 ? "" : "s")" : "À PROXIMITÉ")
                .font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
            if !searching {
                Text(viewModel.locationMessage).font(.footnote).foregroundStyle(.secondary)
                if viewModel.location != nil && results.isEmpty {
                    Text("Aucun arrêt T2C dans un rayon de 5 km. Vérifiez votre position ou recherchez un arrêt.")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                if viewModel.location != nil {
                    Button("Actualiser ma position") { viewModel.locate() }
                        .font(.subheadline).padding(.vertical, 8)
                }
                if viewModel.location == nil {
                    Button(viewModel.locationDenied ? "Ouvrir les réglages" : "Me localiser") {
                        if viewModel.locationDenied, let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        else { viewModel.locate() }
                    }.font(.subheadline).padding(.vertical, 10)
                }
            }
            if searching && results.isEmpty {
                Text("Aucun arrêt trouvé. Essayez un autre nom.")
                    .foregroundStyle(.secondary).padding(.vertical, 20)
            }
            LazyVStack(spacing: 0) {
                ForEach(results) { station in
                    NavigationLink {
                        StationDestinationView(station: station)
                    } label: {
                        HStack(spacing: 16) {
                            VStack(spacing: 5) {
                                if station.lines.contains(where: { $0.isTram }) { Image(systemName: "tram.fill") }
                                if station.lines.contains(where: { !$0.isTram }) { Image(systemName: "bus.fill") }
                            }.font(.title3).frame(width: 26).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(station.name).font(.headline).foregroundStyle(.primary)
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 5) {
                                        ForEach(station.lines) { line in LineBadgeView(line: line, size: 30) }
                                    }
                                    Text("\(station.lines.count) lignes").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                            if let distance = viewModel.distance(to: station) {
                                Text(distance < 1000 ? "\(Int(distance.rounded())) m" : String(format: "%.1f km", distance / 1000))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 20).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

// MARK: - Badge ligne

struct LineBadgeView: View {

    let line: T2CLine

    var size: CGFloat = 48

    private var prefix: String? {
        let name = line.shortName.uppercased().replacingOccurrences(of: " ", with: "")
        guard let first = name.first, "ESP".contains(first), name.count > 1 else { return nil }
        return String(first)
    }
    var body: some View {
        HStack(spacing: 0) {
            if let prefix {
                Text(prefix)
                    .font(.system(size: size * 0.32, weight: .heavy, design: .default))
                    .frame(width: size * 0.25, height: size * 0.72)
                    .foregroundStyle(.white).background(.black)
            }
            Text(prefix == nil ? line.shortName : String(line.shortName.replacingOccurrences(of: " ", with: "").dropFirst()))
                .font(.system(size: size * 0.47, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.4).lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 3)
                .foregroundStyle(Color(hex: line.textColorHex))
                .background(Color(hex: line.colorHex))
        }
        .frame(width: size, height: size * 0.72)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .accessibilityLabel("Ligne \(line.shortName)")
    }
}

// MARK: - Alert Card

struct AlertCardView: View {

    let alert: T2CAlert

    var body: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            HStack(
                alignment: .top,
                spacing: 10
            ) {

                Image(
                    systemName: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)

                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {

                    Text(alert.title)
                        .font(.headline)

                    if let disruptionLevel =
                        alert.disruptionLevel,
                       !disruptionLevel.isEmpty {

                        Text(disruptionLevel)
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !alert.text.isEmpty {

                Text(alert.text)
                    .font(.subheadline)
            }

            if let updatedAt =
                alert.updatedAt {

                Label(
                    "Mise à jour : \(updatedAt)",
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            Color(
                uiColor: .secondarySystemGroupedBackground
            )
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 16
            )
        )
    }
}

// MARK: - Couleur HEX

extension Color {

    init(hex: String) {

        let cleaned = hex
            .trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted
            )

        var value: UInt64 = 0

        Scanner(
            string: cleaned
        )
        .scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double

        if cleaned.count == 6 {

            red =
                Double(
                    (value >> 16) & 0xFF
                ) / 255

            green =
                Double(
                    (value >> 8) & 0xFF
                ) / 255

            blue =
                Double(
                    value & 0xFF
                ) / 255

        } else {

            red = 0.15
            green = 0.35
            blue = 0.75
        }

        self.init(
            red: red,
            green: green,
            blue: blue
        )
    }
}

#Preview {

    HomeView()
}
