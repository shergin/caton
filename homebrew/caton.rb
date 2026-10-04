# Homebrew cask for Caton, the GitHub notifications menu bar app.
#
# Canonical copy; the live cask is Casks/caton.rb in shergin/homebrew-tap.
# scripts/release.sh --publish fills in version and sha256 and updates both.
cask "caton" do
  version "0.3.0"
  sha256 "4ad1dd0a763588f42b4d2ed616dbb3820bd023121bd4617c51d6e459dc8b74a9"

  url "https://github.com/shergin/caton/releases/download/v#{version}/Caton-#{version}.zip"
  name "Caton"
  desc "Menu bar inbox for GitHub notifications that shows only what needs you"
  homepage "https://github.com/shergin/caton"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Caton.app"

  uninstall quit: "dev.caton.Caton"

  zap trash: [
    "~/Library/Application Support/Caton",
    "~/Library/Caches/dev.caton.Caton",
    "~/Library/Preferences/dev.caton.Caton.plist",
  ]

  caveats <<~EOS
    Caton is not notarized, so macOS blocks its first launch. Open System
    Settings > Privacy & Security and click Open Anyway, once.
  EOS
end
