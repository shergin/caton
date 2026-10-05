import AppKit
import CatonCore
import SwiftUI

/// Version, updates, this week's numbers and where Caton comes from.
struct AboutView: View {
    let model: AppModel
    let updates: Updates

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    LogoImage(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Caton").font(.title2.weight(.semibold))
                        Text("Version \(updates.currentVersion)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Button("Check for Updates") { Task { await updates.check(userInitiated: true) } }
                            .disabled(updates.isChecking)
                        if let release = updates.available {
                            HStack(spacing: 6) {
                                Text(Updates.upgradeCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Button("Copy") { updates.copyUpgradeCommand() }.controlSize(.small)
                            }
                            Link("What's new in \(release.version)", destination: release.url).font(.caption)
                        } else if let status = updates.status {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                let week = model.accounts.session?.weekTally ?? Tally()
                LabeledContent("Cleared by rules", value: "\(week.byRules)")
                LabeledContent("Cleared by you", value: "\(week.byYou)")
            } header: {
                Text("This week")
            } footer: {
                Text("Counted on this Mac only. Caton has no server and sends no telemetry.")
            }
            Section("Acknowledgements") {
                Text("Built on Baton, a GraphQL client for SwiftUI. Reads GitHub's notifications REST API and GraphQL API.")
                    .foregroundStyle(.secondary)
                Link("github.com/shergin/caton", destination: AppInfo.repository)
                Text("MIT License").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
