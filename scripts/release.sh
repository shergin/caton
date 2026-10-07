#!/bin/sh
# Cuts a release of the version in Sources/Caton/App/AppInfo.swift: tests,
# builds the app, zips it into build/ and writes the cask with its
# sha256 to build/caton.rb.
#
# With --publish it then tags v<version>, creates the GitHub Release with the
# zip, records the cask in homebrew/caton.rb here, and updates
# Casks/caton.rb in shergin/homebrew-tap. Run it from a clean master that
# matches origin, after bumping the version.
set -e
cd "$(dirname "$0")/.."

publish=false
[ "$1" = "--publish" ] && publish=true

version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/Caton/App/AppInfo.swift)
tag="v$version"
zip="build/Caton-$version.zip"

if $publish; then
  [ -z "$(git status --porcelain)" ] || { echo "The working tree has changes; commit them first." >&2; exit 1; }
  [ "$(git rev-parse --abbrev-ref HEAD)" = master ] || { echo "Release from master." >&2; exit 1; }
  git fetch -q origin
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/master)" ] || { echo "master and origin/master differ; push or pull first." >&2; exit 1; }
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git ls-remote --exit-code --tags origin "$tag" >/dev/null; then
    echo "$tag exists; bump AppInfo.version first." >&2
    exit 1
  fi
fi

swift test
./scripts/bundle.sh
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent build/Caton.app "$zip"
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
sed -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" homebrew/caton.rb > build/caton.rb

if ! $publish; then
  echo "Built $zip"
  echo "sha256 $sha"
  echo "Cask: build/caton.rb. Run with --publish to release $tag."
  exit 0
fi

# Notes: the commits since the last release, or a first-release note.
previous=$(git describe --tags --abbrev=0 2>/dev/null || true)
notes=build/release-notes.md
{
  if [ -n "$previous" ]; then
    git log --reverse --invert-grep --grep='^Record v' --pretty='- %s' "$previous..HEAD"
  else
    echo "The first release of Caton."
  fi
  echo
  echo '```sh'
  echo 'brew install --cask shergin/tap/caton'
  echo '```'
  echo
  echo "Caton is not notarized: on first launch, open System Settings > Privacy & Security and click Open Anyway."
} > "$notes"

git tag -a "$tag" -m "Caton $version"
git push -q origin "$tag"
gh release create "$tag" "$zip" --title "Caton $version" --notes-file "$notes"

cp build/caton.rb homebrew/caton.rb
git add homebrew/caton.rb
git commit -q -m "Record $tag release"
git push -q origin master

tap=$(mktemp -d)
gh repo clone shergin/homebrew-tap "$tap" -- -q
mkdir -p "$tap/Casks"
if [ -f "$tap/Casks/caton.rb" ]; then message="Bump caton to $version"; else message="Add caton cask"; fi
cp homebrew/caton.rb "$tap/Casks/caton.rb"
git -C "$tap" add Casks/caton.rb
git -C "$tap" commit -q -m "$message"
git -C "$tap" push -q
rm -rf "$tap"

echo "Released $tag: https://github.com/shergin/caton/releases/tag/$tag"
