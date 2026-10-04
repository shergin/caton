# Homebrew cask for Caton, the GitHub notifications menu bar app.
#
# Canonical copy; the live cask is Casks/caton.rb in shergin/homebrew-tap.
# scripts/release.sh --publish fills in version and sha256 and updates both.
cask "caton" do
  version "0.2.0"
  sha256 "8e8ef2ab11a0a69f8d54c14327ce3328c6b50917e0621713c49a602b3f34b2dc"

  url "https://github.com/shergin/caton/releases/download/v#{version}/Caton-#{version}.zip"
  name "Caton"
  desc "Menu bar inbox for GitHub notifications that shows only what needs you"
  homepage "https://github.com/shergin/caton"

  livecheck do
    url :url
    strategy :github_latest
  end

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
