import CatonCore
import SwiftUI

struct SignInView: View {
    @Bindable var model: AppModel
    @State private var token = ""
    @State private var showsEnterprise = false
    @State private var enterpriseHost = ""

    /// github.com, or the Enterprise host typed in.
    private var host: GitHubHost {
        showsEnterprise ? GitHubHost(enterpriseHost) ?? .dotCom : .dotCom
    }

    /// A classic token with the scopes the chosen access needs.
    private var tokenURL: URL {
        let scopes = model.preferences.access.scopes.replacingOccurrences(of: " ", with: ",")
        return URL(string: "\(host.webURL.absoluteString)/settings/tokens/new?scopes=\(scopes)&description=Caton")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LogoImage(size: 40)
                Text(model.accounts.isAdding ? "Add an account" : "Caton").font(.system(size: 20, weight: .semibold))
                Spacer()
                if model.accounts.isAdding {
                    Button("Cancel") { model.accounts.cancelAdding() }
                }
            }
            Text("The GitHub inbox that shows only what needs you. Sign in to read your notifications; your token stays on this Mac.")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.account == .connecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Signing in…").font(Theme.Font.body)
                }
            } else if case .waiting(let code, let url) = model.accounts.deviceSignIn {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter this code on GitHub (copied):").font(Theme.Font.body)
                    Text(code).font(.system(size: 24, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Link("Open \(url.host() ?? "github.com")", destination: url).font(Theme.Font.body)
                        Spacer()
                        Button("Cancel") { model.accounts.cancelSignIn() }
                    }
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for approval…").font(Theme.Font.detail).foregroundStyle(.secondary)
                    }
                }
            } else {
                methods
            }

            if let error = model.accounts.signInError {
                Text(error).font(Theme.Font.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("Caton reads notifications with a classic-scope token. GitHub does not let fine-grained tokens or GitHub App tokens read notifications.")
                .font(Theme.Font.caption)
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
                .font(Theme.Font.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if host.isDotCom {
                Button {
                    model.accounts.signInWithDeviceFlow()
                } label: {
                    Label("Sign in with GitHub", systemImage: "person.badge.key").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(DeviceFlow.clientID == nil)
                .help(DeviceFlow.clientID == nil ? "Needs an OAuth App client id (CatonGitHubClientID)" : "Opens github.com with a one-time code")
            }

            if GitHubCLI.executable != nil {
                Button {
                    model.accounts.signInWithGitHubCLI(host: host)
                } label: {
                    Label(host.isDotCom ? "Use my GitHub CLI login" : "Use my GitHub CLI login for \(host.name)", systemImage: "terminal").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            Divider().padding(.vertical, 2)
            Text("Or paste a classic token").font(Theme.Font.detail).foregroundStyle(.secondary)
            HStack {
                SecureField("ghp_…", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.accounts.signIn(token: token, host: host) }
                Button("Sign in") { model.accounts.signIn(token: token, host: host) }
                    .disabled(token.isEmpty)
            }
            Link("Create a token with the right scopes →", destination: tokenURL)
                .font(Theme.Font.detail)
            DisclosureGroup("GitHub Enterprise", isExpanded: $showsEnterprise) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("github.acme.com or acme.ghe.com", text: $enterpriseHost)
                        .textFieldStyle(.roundedBorder)
                    Text(enterpriseHost.isEmpty || GitHubHost(enterpriseHost) != nil
                        ? "Sign in with a classic token from that host, or the GitHub CLI signed in to it."
                        : "That doesn't look like a host name.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(Theme.Font.detail)
            Divider().padding(.vertical, 2)
            if !model.accounts.isAdding {
                Button {
                    model.enterPractice()
                } label: {
                    Label("Try a practice inbox first", systemImage: "graduationcap")
                }
                .buttonStyle(.link)
                .font(Theme.Font.body)
                .help("Made-up threads to learn the keys on; nothing reaches GitHub")
            }
        }
    }
}
