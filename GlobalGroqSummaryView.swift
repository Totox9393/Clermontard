import SwiftUI

struct GlobalGroqSummaryView: View {
    @ObservedObject var viewModel: GlobalGroqSummaryViewModel
    let lines: [T2CLine]
    @State private var selectedID = ""

    var body: some View {
        if !viewModel.summaries.isEmpty {
            VStack(spacing: 7) {
                TabView(selection: $selectedID) {
                    ForEach(viewModel.summaries) { summary in
                        summaryCard(summary)
                            .tag(summary.id)
                            .padding(.horizontal, 1)
                    }
                }
                .frame(height: 112)
                .tabViewStyle(.page(indexDisplayMode: .never))

                if viewModel.summaries.count > 1 {
                    pageDots
                }
            }
            .onAppear { selectFirstIfNeeded() }
            .onChange(of: viewModel.summaries.map(\.id)) { _, _ in selectFirstIfNeeded() }
            .task(id: selectedID) {
                guard viewModel.summaries.count > 1 else { return }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                let ids = viewModel.summaries.map(\.id)
                let current = ids.firstIndex(of: selectedID) ?? 0
                withAnimation(.easeInOut) {
                    selectedID = ids[(current + 1) % ids.count]
                }
            }
            .accessibilityLabel("Informations générales du réseau T2C")
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(viewModel.summaries) { summary in
                Button { withAnimation(.easeInOut) { selectedID = summary.id } } label: {
                    Circle()
                        .fill(Color.primary.opacity(selectedID == summary.id ? 0.75 : 0.22))
                        .frame(width: selectedID == summary.id ? 7 : 6, height: selectedID == summary.id ? 7 : 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Information \(viewModel.summaries.firstIndex(where: { $0.id == summary.id }).map { $0 + 1 } ?? 1)")
            }
        }
    }

    private func summaryCard(_ summary: GlobalTrafficSummary) -> some View {
        let restored = summary.category.localizedCaseInsensitiveContains("rétablie")
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: restored ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(restored ? Color.green : Color.red)
                Text(summary.category.capitalized)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(restored ? Color.green : Color.red)
                Spacer()
                lineBadges(for: summary)
            }
            Text(summary.resume)
                .font(.body)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background((restored ? Color.green : Color.red).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func lineBadges(for summary: GlobalTrafficSummary) -> some View {
        let refs = Set(summary.affectedRoutes)
        let affected = lines.filter {
            refs.contains($0.routeID) || refs.contains($0.shortName)
        }
        if !affected.isEmpty {
            HStack(spacing: 4) {
                ForEach(affected.prefix(4)) { line in
                    LineBadgeView(line: line, size: 26)
                }
            }
        }
    }

    private func selectFirstIfNeeded() {
        let ids = viewModel.summaries.map(\.id)
        if !ids.contains(selectedID) { selectedID = ids.first ?? "" }
    }
}
