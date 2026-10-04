# Homebrew cask for Caton

[`caton.rb`](caton.rb) is the canonical copy of the cask. The live one is
`Casks/caton.rb` in the tap repo [`shergin/homebrew-tap`](https://github.com/shergin/homebrew-tap).
It installs the universal `Caton.app` from the GitHub Release's zip.

## Install

```sh
brew install --cask shergin/tap/caton
```

Caton is not notarized, so macOS blocks its first launch: open System
Settings › Privacy & Security and click Open Anyway, once. Updates arrive
with `brew upgrade --cask caton`; the app says when one is out.

## Cut a release

1. Bump `version` in `Sources/Caton/App/AppInfo.swift`, commit and push.
2. `./scripts/release.sh` tests, builds `build/Caton-<version>.zip` and writes
   the cask with its sha256 to `build/caton.rb`, publishing nothing.
3. `./scripts/release.sh --publish` does the same from a clean `main`, then
   tags `v<version>`, creates the GitHub Release with the zip, commits the
   cask here ("Record v<version> release") and pushes it to the tap.
4. `brew update && brew upgrade --cask caton` to check the result.

To check the cask before a release, copy it into a throwaway local tap
(`brew tap-new --no-git <user>/<name>`) and run `brew style` and
`brew audit --cask --strict` on it there.
