import SwiftUI

/// Mirrors the original `ActivationActivity` UI: a code field with Activate /
/// Buy / Help / Exit buttons. Activation is verified against `/api/activation/verify`
/// on the same data host as the Android app.
struct ActivationView: View {
    @Environment(AppState.self) private var appState
    @State private var code: String = ""
    @State private var isWorking = false
    @State private var errorText: String?

    private let service = ActivationService()

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    header
                    Text(
                        """
                        Your current package has expired.
                        Please enter the activation code to continue.
                        """
                    )
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineSpacing(4)
                        .padding(.top, Theme.Spacing.s)

                    codeField

                    if let errorText {
                        Text(errorText)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.Colors.live)
                            .transition(.opacity)
                    }

                    primaryButton

                    secondaryButton(title: "Buy Activation Code", icon: "cart.fill") {
                        openBrowser("https://example.com/buy")
                    }
                    secondaryButton(title: "Need Help?", icon: "questionmark.circle.fill") {
                        openBrowser("https://example.com/support")
                    }
                    secondaryButton(title: "Exit", icon: "rectangle.portrait.and.arrow.right.fill",
                                    destructive: true) {
                        exitApp()
                    }
                }
                .padding(Theme.Spacing.xl)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                Text("FCTV33")
                    .font(.title.weight(.heavy))
                    .foregroundStyle(.white)
                Spacer()
            }
            Text("Activation Required")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.top, Theme.Spacing.l)
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter Activation Code")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
            TextField("", text: $code, prompt: Text("XXXX-XXXX-XXXX").foregroundColor(.white.opacity(0.3)))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(Theme.Spacing.m)
                .background(Theme.Colors.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Sizing.cornerMedium)
                        .stroke(Theme.Colors.inputBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Sizing.cornerMedium))
                .onChange(of: code) { _, _ in errorText = nil }
                .submitLabel(.done)
                .onSubmit { Task { await activate() } }
        }
    }

    private var primaryButton: some View {
        Button {
            Task { await activate() }
        } label: {
            ZStack {
                if isWorking {
                    ProgressView().tint(.black)
                } else {
                    Label("Activate", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.black)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.Colors.accent)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Sizing.cornerMedium))
            .opacity(isWorking ? 0.7 : 1.0)
        }
        .disabled(isWorking)
    }

    private func secondaryButton(title: LocalizedStringKey, icon: String,
                                 destructive: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(destructive ? Theme.Colors.live : Color.white.opacity(0.9))
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Theme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Sizing.cornerMedium)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Sizing.cornerMedium))
        }
    }

    private func activate() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let result = await service.validate(code)
        switch result {
        case .success:
            appState.isActivated = true
            appState.route = .home
        case let .invalid(message):
            errorText = message
        case .empty:
            errorText = "Please enter your activation code"
        }
    }

    private func openBrowser(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    private func exitApp() {
        // Apple doesn't allow programmatic termination on iOS in production.
        // We simply suspend the app, which is the closest equivalent.
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
    }
}

#Preview {
    ActivationView().environment(AppState())
}
