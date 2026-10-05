<p align="center">
  <img src="logo.png" alt="Caton's logo: a yellow cat sticking its tongue out" width="128">
</p>

# Caton

A macOS menu bar inbox for GitHub notifications that shows only what needs
you. Caton joins each notification to the live state of its pull request or
issue, clears what no longer needs anyone, and files the rest into four
splits: **Needs me · Team · Following · Feed**. The number in the menu bar is
the number of things waiting on you.

The product thinking is in [PRD.md](PRD.md).

## How it is built

- **CatonCore** (no UI, no network library): the REST client for GitHub's
  notifications feed (the feed has no GraphQL equivalent), the classifier,
  the action queue with its undo window, and the inbox projection. Pure and
  tested.
- **Caton** (the app): an AppKit status item and non-activating panel hosting
  SwiftUI, with subject state through [Baton](https://github.com/shergin/baton). Each pull request
  and issue row reads its state through a fragment beside the view; the
  operations the model owns and the facts the classifier reads are in
  [`Subjects.graphql`](Sources/Caton/Graph/Subjects.graphql) beside the
  store. The first fetch of a subject goes through `repository(owner:name:)`,
  later refreshes through `nodes(ids:)` in batches into the same records,
  and a relaunch classifies the inbox from Baton's on-disk image before the
  network answers.
- **My PRs** (`g p`) is the part to read for Baton: a screen with no REST
  behind it. Its query and paged connection are in
  [`MyPullRequestsView.swift`](Sources/Caton/Views/Panel/MyPullRequestsView.swift),
  and its row and the fragment that says where a pull request stands in
  [`PullRequestRow.swift`](Sources/Caton/Views/Rows/PullRequestRow.swift),
  each beside the view that reads it. The app model asks for the same query by
  value and so shares the view's handle, rows reuse the inbox's own
  fragments, and the list renders from the image at launch. Its two writes,
  nudge and ready for review, are mutations in
  [`PullRequestWrites.graphql`](Sources/Caton/Graph/PullRequestWrites.graphql)
  with typed optimistic responses; `WriteTests` plays GitHub to show the
  optimistic answer, the server's, and a refusal taken back.

## Running

Caton builds against a checkout of [Baton](https://github.com/shergin/baton)
beside it (`Package.swift` names `../baton`):

```sh
git clone https://github.com/shergin/baton.git
git clone https://github.com/shergin/caton.git
baton/scripts/build-compiler.sh   # Baton's GraphQL compiler, needs Rust; again after pulling Baton
cd caton
```

```sh
swift test
CATON_DRY_RUN=1 ./scripts/run.sh
```

`CATON_DRY_RUN=1` keeps every change local: nothing is marked read, done or
unsubscribed on GitHub. `CATON_GITHUB_TOKEN=$(gh auth token)` signs in without
the sign-in screen. Debug builds also take `CATON_OPEN_PANEL=1`,
`CATON_SECTION=0…3`, `CATON_PRACTICE=1` (opens the practice inbox),
`CATON_OVERLAY=peek|help|commands|snooze|why|tips|zero|none`,
`CATON_SNAPSHOT=/path.png` (renders the panel to a file) and `CATON_DUMP=1`
(prints the classified inbox to stderr).

Not signed in yet, or new to the keys? "Try a practice inbox first" on the
sign-in screen (or "Practice inbox" in `⌘K`) opens made-up threads that fill
every split; nothing there reaches GitHub or is saved.

`./scripts/icons.sh` renders the menu bar images, the in-app logo and the app
icon into `Sources/Caton/Resources` from `logo.png` and `icon-*.png` at the
root; run it after changing those.

`./scripts/bundle.sh` builds `build/Caton.app` for Apple silicon,
versioned from `Sources/Caton/App/AppInfo.swift`; `./scripts/release.sh`
zips it for a release ([homebrew/README.md](homebrew/README.md) has the steps). Releases are meant to ship as a Homebrew
cask in Caton's own tap, so `brew upgrade --cask caton` installs updates; the app checks GitHub
Releases once a day and from "Check for Updates…" and shows that command when
a newer version is out.

"Sign in with GitHub" uses the device flow of Caton's OAuth App (client id
`Ov23liz9s5AlvZVZWZ2k`; no secret is involved); `CATON_GITHUB_CLIENT_ID`
points it at another OAuth App with device flow enabled. It asks for
`notifications repo`, or `notifications public_repo` in Lite mode (private
pull requests then show no state). The GitHub CLI's login and a classic token
with those scopes also work. GitHub's notifications API does not accept
fine-grained tokens or GitHub App tokens.

## Accounts

Several accounts can be signed in, on github.com, a GitHub Enterprise Cloud
tenant (`acme.ghe.com`) or a GitHub Enterprise Server host (sign in to those
with a token or the GitHub CLI). One shows at a time, each with its own
rules, snoozes, saved searches and Cleared log; switch from the gear menu,
Settings or `⌘K`.

Requires macOS 26 and Swift 6.2, as Baton does.

`swift test` runs two suites: `CatonCoreTests` (classifier, projection, queue,
REST client, alerts, search) and `CatonTests` (the app model's verbs, against
a throwaway state file and user defaults).

## Keys

`j`/`k` move, `⏎`/`o` open, `e`/`d` done, `h` snooze, `u` unsubscribe, `b`
later, `m` mark read, `p` peek, `x` select, `z` undo, `y` copy link, `/`
search, `⇥` next split, `1`–`4` splits, `5`–`9` saved searches, `→`/`←` open
and close a Feed bundle, `⌘K` commands, `⌘,` settings, `?` all keys (also in
Settings › Shortcuts). The global shortcut is `⌘'` by default (`⌥⌘'` when
another app holds it); a second one, off by default, opens straight into
Needs me.

My PRs (`g p`, or the `…` menu) lists your open pull requests by whose move
it is, with "waiting on @alex · 3d" and the like; `h` there sets a reminder
that joins Needs me if nobody has reviewed or commented by then. `n` nudges:
it asks the reviewers again (also from a Follow up row, which it then
ends), and `⇧R` marks a draft ready for review. Both wait out the undo
window, like every verb, and a dry run only says what they would do.

In the snooze picker, `n` switches to a follow-up: the thread comes back on
any new activity, and at the chosen time only if nothing happened ("back: no
reply yet"). `⌘K` › "Why is this here?" explains a thread's split, and "Get
me to zero…" previews each bulk clear with its count.

Feed bundles what one bot sent and what a busy repository sent into single
rows; `e` on a bundle clears all of it. The header's window button (or `⌘K`)
moves the inbox into an ordinary window that stays open.

Search takes words and GitHub-style qualifiers, each negatable with `-`:
`repo:`, `org:`, `author:`, `reason:` (`review`, `mention`, `team`, …), `is:`
(`pr`, `issue`, `draft`, `unread`, `open`, `closed`, `merged`, `bot`) and
`ci:` (`failing`, `passing`, `pending`). "Save as split" keeps a search as a
tab after Feed.

## Alerts

The bundled app shows a banner when something new needs you: Needs me only,
at most three per poll (adjustable) and a summary for the rest, never while
the panel is open, and silent outside working hours (9:00–19:00 on weekdays by
default). The first poll after launch announces nothing; what is already there
is seen. An optional morning digest sums up what waits and what rules cleared
overnight.

## Rules

Four rules run by default and log what they clear in the Cleared view, where
each can be restored: merged or closed subjects outside Needs me are cleared,
drafts that do not request you go to Feed, bot pull requests go to Feed, and
muted repositories are cleared. Rules never touch Needs me. Until you turn on
"Mark rule-cleared threads done on GitHub", rule clears stay on this Mac.

## License

Licensed under the [MIT License](LICENSE).
