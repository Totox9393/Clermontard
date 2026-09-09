import SwiftUI

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var logoVisible = false
    @State private var titleVisible = false
    @State private var continueVisible = false
    @State private var loadingProgress = 0.08
    @State private var loadingLabel = "Préparation du réseau T2C…"
    @State private var loadingFailed = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if entered {
                MainTabsView().transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    VStack(spacing: 30) {
                        Image("Logo_T2C")
                            .resizable().scaledToFit()
                            .frame(width: 144, height: 120)
                            .opacity(logoVisible ? 1 : 0)
                            .scaleEffect(logoVisible || reduceMotion ? 1 : 0.82)
                            .offset(y: logoVisible || reduceMotion ? 0 : 14)
                            .accessibilityLabel("T2C")
                        VStack(spacing: 12) {
                            BrandTitle(large: true)
                            Text("Votre prochain départ.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .opacity(titleVisible ? 1 : 0)
                        .offset(y: titleVisible || reduceMotion ? 0 : 12)
                    }
                    Spacer(minLength: 32)
                    VStack(spacing: 10) {
                        ProgressView(value: loadingProgress)
                            .tint(Color(hex: "C60024"))
                        HStack(spacing: 7) {
                            if loadingProgress >= 1 {
                                Image(systemName: loadingFailed ? "exclamationmark.circle" : "checkmark.circle.fill")
                            }
                            Text(loadingLabel)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .opacity(titleVisible ? 1 : 0)
                    .padding(.bottom, 24)
                    Button {
                        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.3)) { entered = true }
                    } label: {
                        Text("Continuer")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .trailing) { Image(systemName: "arrow.right") }
                            .padding(20)
                            .foregroundStyle(.white)
                            .background(Color(hex: "C60024"), in: Capsule())
                    }
                    .opacity(continueVisible ? 1 : 0)
                    .offset(y: continueVisible || reduceMotion ? 0 : 8)
                    .disabled(!continueVisible)
                    .accessibilityHidden(!continueVisible)
                    .padding(.bottom, 28)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 480)
                .task {
                    async let animation: Void = playIntroduction()
                    async let loading: Void = preloadNetwork()
                    _ = await (animation, loading)
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.4)) {
                        continueVisible = true
                    }
                }
            }
        }
        .tint(Color(hex: "C60024"))
    }

    @MainActor
    private func playIntroduction() async {
        if reduceMotion {
            logoVisible = true
            titleVisible = true
            return
        }
        withAnimation(.spring(response: 0.75, dampingFraction: 0.8)) { logoVisible = true }
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        withAnimation(.easeOut(duration: 0.55)) { titleVisible = true }
        do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
    }

    @MainActor
    private func preloadNetwork() async {
        do {
            loadingProgress = 0.18
            loadingLabel = "Chargement des arrêts…"
            _ = try await T2CService.shared.getStations()
            loadingProgress = 0.82
            loadingLabel = "Classement des lignes…"
            _ = try await T2CService.shared.getLines()
            loadingProgress = 1
            loadingLabel = "Réseau prêt"
        } catch {
            loadingFailed = true
            loadingProgress = 1
            loadingLabel = "Chargement incomplet — vous pourrez réessayer dans l’app"
        }
    }
}

struct MainTabsView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Accueil", systemImage: "house.fill") }
            TimetablesView()
                .tabItem { Label("Horaires", systemImage: "clock.fill") }
            ThermometerView()
                .tabItem { Label("Thermomètre", systemImage: "thermometer.medium") }
            SettingsView()
                .tabItem { Label("Paramètres", systemImage: "gearshape.fill") }
        }
    }
}

struct BrandTitle: View {
    var large = false
    var body: some View {
        Text("ClermonTard")
            .font(.system(size: large ? 40 : 32, weight: .bold, design: .default))
            .tracking(large ? -1.8 : -1.2)
            .lineLimit(1).minimumScaleFactor(0.65)
    }
}

struct BrandHeader: View {
    var large = false
    var body: some View {
        VStack(spacing: 16) {
            Image("Logo_T2C")
                .resizable().scaledToFit()
                .frame(width: large ? 132 : 78, height: large ? 112 : 65)
                .accessibilityLabel("T2C")
            BrandTitle(large: large)
        }.frame(maxWidth: .infinity)
    }
}

#Preview { ContentView() }
