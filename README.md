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

`./scripts/bundle.sh` builds `build/Caton.app`. "Sign in with GitHub" needs
the client id of a GitHub OAuth App with device flow enabled, passed as
`CATON_GITHUB_CLIENT_ID` when bundling; until then, sign in with the GitHub
CLI's login or a classic token with the `notifications` and `repo` scopes.
GitHub's notifications API does not accept fine-grained tokens.

Requires macOS 26 and Swift 6.2, as Baton does.

## Keys

`j`/`k` move, `⏎`/`o` open, `e`/`d` done, `h` snooze, `u` unsubscribe, `b`
later, `m` mark read, `x` select, `z` undo, `y` copy link, `/` search, `⇥`
next split, `1`–`4` splits, `⌘K` commands, `?` all keys. The global shortcut
is `⌘'` (or `⌥⌘'` when another app holds it).

## Rules

Four rules run by default and log what they clear in the Cleared view, where
each can be restored: merged or closed subjects outside Needs me are cleared,
drafts that do not request you go to Feed, bot pull requests go to Feed, and
muted repositories are cleared. Rules never touch Needs me. Until you turn on
"Mark rule-cleared threads done on GitHub", rule clears stay on this Mac.
