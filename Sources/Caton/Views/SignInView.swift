import SwiftUI

struct SignInView: View {
    @Bindable var model: AppModel
    @State private var token = ""

    /// A classic token with the scopes the chosen access needs.
    private var tokenURL: URL {
        let scopes = model.preferences.access.scopes.replacingOccurrences(of: " ", with: ",")
        return URL(string: "https://github.com/settings/tokens/new?scopes=\(scopes)&description=Caton")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LogoImage(size: 40)
                Text("Caton").font(.system(size: 20, weight: .semibold))
            }
            Text("The GitHub inbox that shows only what needs you. Sign in to read your notifications; your token stays on this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.account == .connecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Signing in…").font(.system(size: 12))
                }
            } else if case .waiting(let code, let url) = model.deviceSignIn {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter this code on GitHub (copied):").font(.system(size: 12))
                    Text(code).font(.system(size: 24, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Link("Open \(url.host() ?? "github.com")", destination: url).font(.system(size: 12))
                        Spacer()
                        Button("Cancel") { model.cancelSignIn() }
                    }
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for approval…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else {
                methods
            }

            if let error = model.signInError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("Caton reads notifications with a classic-scope token. GitHub does not let fine-grained tokens or GitHub App tokens read notifications.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    @ViewBuilder private var methods: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Access", selection: Binding(get: { model.preferences.access }, set: { model.preferences.access = $0 })) {
                ForEach(DeviceFlow.Access.allCases, id: \.self) { access in
                    Text(access == .full ? "Private and public repositories" : "Public repositories only").tag(access)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.preferences.access.explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.signInWithDeviceFlow()
            } label: {
                Label("Sign in with GitHub", systemImage: "person.badge.key").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(DeviceFlow.clientID == nil)
            .help(DeviceFlow.clientID == nil ? "Needs an OAuth App client id (CatonGitHubClientID)" : "Opens github.com with a one-time code")

            if GitHubCLI.executable != nil {
                Button {
                    model.signInWithGitHubCLI()
                } label: {
                    Label("Use my GitHub CLI login", systemImage: "terminal").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            Divider().padding(.vertical, 2)
            Text("Or paste a classic token").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                SecureField("ghp_…", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.signIn(token: token) }
                Button("Sign in") { model.signIn(token: token) }
                    .disabled(token.isEmpty)
            }
            Link("Create a token with the right scopes →", destination: tokenURL)
                .font(.system(size: 11))
        }
    }
}

/// The logo at a size in points.
struct LogoImage: View {
    let size: CGFloat

    var body: some View {
        if let logo = Assets.logo {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
