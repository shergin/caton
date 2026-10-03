<p align="center">
  <img src="logo.png" alt="Caton's logo: a yellow cat sticking its tongue out" width="128">
</p>

# Caton

A macOS menu bar inbox for GitHub notifications that shows only what needs
you. Caton joins each notification to the live state of its pull request or
issue, clears what no longer needs anyone, and files the rest into four
splits: **Needs me · Team · Following · Feed**. The number in the menu bar is
the number of things waiting on you.

The product thinking is in [PRD.md](PRD.md); the research behind it is in
[research/](research/).

## How it is built

- **CatonCore** (no UI, no network library): the REST client for GitHub's
  notifications feed (the feed has no GraphQL equivalent), the classifier,
  the action queue with its undo window, and the inbox projection. Pure and
  tested.
- **Caton** (the app): an AppKit status item and non-activating panel hosting
  SwiftUI, with subject state through [Baton](../baton). Each pull request
  and issue row reads its state through a fragment beside the view; the
  first fetch of a subject goes through `repository(owner:name:)`, later
  refreshes through `nodes(ids:)` in batches into the same records, and a
  relaunch classifies the inbox from Baton's on-disk image before the
  network answers.

## Running

```sh
swift test
CATON_DRY_RUN=1 ./scripts/run.sh
```

`CATON_DRY_RUN=1` keeps every change local: nothing is marked read, done or
unsubscribed on GitHub. `CATON_GITHUB_TOKEN=$(gh auth token)` signs in without
the sign-in screen. Debug builds also take `CATON_OPEN_PANEL=1`,
`CATON_SECTION=0…3`, `CATON_SNAPSHOT=/path.png` (renders the panel to a file)
and `CATON_DUMP=1` (prints the classified inbox to stderr).

`./scripts/icons.sh` renders the menu bar images, the in-app logo and the app
icon into `Sources/Caton/Resources` from `logo.png` and `icon-*.png` at the
root; run it after changing those.

`./scripts/bundle.sh` builds `build/Caton.app`. "Sign in with GitHub" uses
the device flow of Caton's OAuth App (client id `Ov23liz9s5AlvZVZWZ2k`; no
secret is involved); `CATON_GITHUB_CLIENT_ID` points it at another OAuth App
with device flow enabled. The GitHub CLI's login and a classic token with the
`notifications` and `repo` scopes also work. GitHub's notifications API does
not accept fine-grained tokens or GitHub App tokens.

Requires macOS 26 and Swift 6.2, as Baton does.

`swift test` runs two suites: `CatonCoreTests` (classifier, projection, queue,
REST client, alerts, search) and `CatonTests` (the app model's verbs, against
a throwaway state file and user defaults).

## Keys

`j`/`k` move, `⏎`/`o` open, `e`/`d` done, `h` snooze, `u` unsubscribe, `b`
later, `m` mark read, `p` peek, `x` select, `z` undo, `y` copy link, `/`
search, `⇥` next split, `1`–`4` splits, `⌘K` commands, `⌘,` settings, `?`
all keys. The global shortcut is `⌘'` by default (`⌥⌘'` when another app
holds it) and can be changed in Settings.

Search takes words and GitHub-style qualifiers, each negatable with `-`:
`repo:`, `org:`, `author:`, `reason:` (`review`, `mention`, `team`, …), `is:`
(`pr`, `issue`, `draft`, `unread`, `open`, `closed`, `merged`, `bot`) and
`ci:` (`failing`, `passing`, `pending`).

## Alerts

The bundled app shows a banner when something new needs you: Needs me only,
at most three per poll and a summary for the rest, never while the panel is
open, and silent outside working hours (9:00–19:00 on weekdays by default).
The first poll after launch announces nothing; what is already there is seen.

## Rules

Four rules run by default and log what they clear in the Cleared view, where
each can be restored: merged or closed subjects outside Needs me are cleared,
drafts that do not request you go to Feed, bot pull requests go to Feed, and
muted repositories are cleared. Rules never touch Needs me. Until you turn on
"Mark rule-cleared threads done on GitHub", rule clears stay on this Mac.
