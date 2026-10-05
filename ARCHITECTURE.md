# Architecture

Caton is a menu-bar inbox for GitHub notifications, and it is a working
example of [Baton](https://github.com/shergin/baton), a Relay-style GraphQL
client for SwiftUI. This document describes the code as it is: the layers,
where each kind of state lives, how a key press becomes a change on GitHub,
and where Baton begins and ends. `PRD.md` explains why the product works
the way it does.

## Layers

```
App/          AppKit shell: status item, panel, window, hot key, banners
Views/        SwiftUI: Panel/, Rows/, Overlays/, Settings/
Keys/         KeyPress -> KeyRouter -> the Command table
Model/        AppModel (root) · Accounts · Session · Panel
Graph/        Baton: SubjectStore and the model's .graphql documents
Auth/         sign-in, tokens
CatonCore     pure: REST client, classifier, projection, queue, layout
```

Dependencies point down. CatonCore depends only on Foundation, so it has
no SwiftUI, no AppKit and no Baton, and everything that decides what shows
where is tested there. Baton lives in the app target: the views, `Graph/`,
and the session's connection and pull request code.

## CatonCore: decisions as functions

- `GitHubREST` is an actor for the notifications feed. GitHub has no
  GraphQL for notifications. It sends conditional requests
  (`If-Modified-Since`, so an unchanged feed costs a free 304), follows
  `X-Poll-Interval`, and has the four verbs: mark read, done, unsubscribe
  and ignore.
- `Classifier` takes a thread and its subject's facts and returns a
  `Classification`: the split, a badge, and `because`, the sentence the
  "Why is this here?" card shows.
- `InboxProjection.project(threads:reviewRequests:reminders:facts:state:now:)`
  returns an `InboxSnapshot`: the four splits, Snoozed, Later, the rule
  clears to apply, and the snoozes that woke up. It is a pure function,
  so the same inputs always give the same inbox.
- `LocalState` is everything Caton knows that GitHub does not: dismissals
  keyed by the activity they cover, read marks, snoozes, Later, rules, the
  bot, AI-reviewer and agent lists, saved searches, reminders, the Cleared
  log and the weekly tallies.
- `ActionQueue` holds verbs waiting out their undo window. Verbs are
  grouped in batches, and undo works on a batch.
- `ListLayout` turns items into the rows the list draws: repository
  headers, Feed bundles and items.

### Identity

The inbox holds three kinds of row, and `ItemID` names them:

- `.thread(id)`: a notification thread from the feed.
- `.reviewRequest(nodeID)`: an open pull request that asks for the viewer's
  review but has no thread.
- `.followUp(nodeID)`: a reminder Caton made on one of the viewer's pull
  requests, which joins Needs me when it comes due.

`RowID` adds the rows of the list that are not items: `.header`, `.bundle`,
and `.pullRequest` in My PRs. `ItemID` is saved as its string key, so the
saved state stays plain JSON. The kind of a row, `RowKind`, decides which
commands apply to it.

## Model: one object per job

### Session: one inbox

A `Session` is one inbox and everything that keeps it up to date. Its source
is either `.github(Connection)` (REST, a Baton environment, the subject
store and the on-disk image) or `.local(facts:)`, which connects to nothing
and serves the practice inbox and the tests.

- **Life** (`Session.swift`): `start()` polls the feed at least every 60
  seconds and merges the result into the threads. It syncs the subject
  store, then `recompute()` projects a new snapshot and saves it.
- **Changes** (`Session+Changes.swift`): each verb records local state,
  queues its action when it should reach GitHub, and returns an `Undo`
  that takes it back.
- **Dispatch** (`Session+Dispatch.swift`): the dispatcher sends due actions
  one at a time, paced as GitHub asks. Only `.thread` items exist on
  GitHub; a dry run, or a session connected to nothing, sends nothing.
- **Pull requests** (`Session+PullRequests.swift`): the viewer's open pull
  requests read from the handle shared with My PRs, the reminders set on
  them, and the two writes, nudge and ready for review. Writes are Baton
  mutations with typed optimistic responses, held for the same undo
  window.

The session reports through callbacks (`onChange`, `onPoll`,
`onUnauthorized`, `onWrite`) and knows nothing about the panel or alerts.
Switching accounts or entering practice swaps the whole session, so nothing
is reset by hand. The practice session saves nowhere.

### Accounts: signing in

`Accounts` handles the sign-in flows (a token, the `gh` CLI's token, or the
device flow), the list of accounts and their tokens, and the session of the
one that shows. Each account's session gets its own Baton `Environment` and
its own `Persistence` image, versioned by the schema digest. `use(_:)` is
how tests sign in.

### Panel: where the user is

`Panel` is UI state: the section, the selection and checks, the search and
filters, the overlay, and the toasts. The list it shows (`items`, `rows`,
`savedCounts`) is **stored, not computed on read**. `relayout()` rebuilds it
when an input changes. Each input property calls it in its `didSet`, and
`AppModel` calls `inboxChanged()` when the session's snapshot changes. A
keystroke reads the list many times. Computing it on read took 17 ms per
keystroke at 1,000 threads; reading a stored list takes 0.01 ms, and
observation tells exactly the views that read it. `batch {}` turns several
changes into one layout.

### AppModel: the root

`AppModel` owns `Accounts`, the `Panel`, the practice session and the undo
stack. It points the panel at whichever session shows, and it connects
session events to the panel and to alerts. Its commands live in
`AppModel+Commands.swift` and `AppModel+PullRequests.swift`. Each command
finds its rows in the panel, asks the session to change them, keeps the
undo, and says what happened in a toast. A command handles only its own
kind of row; which command a key runs is the command table's call.

## Keys: one table

```
NSEvent -> KeyPress -> KeyRouter -> overlay handler | g prefix | Command.match -> run
```

- `KeyPress` is a key as the panel reads it. It is built from an `NSEvent`,
  or by hand in tests.
- `KeyRouter` gives the key to the overlay on top first. Each overlay
  handles its keys in a `handle(_:model:)` beside its view, and returns
  one of three outcomes: it took the key, its text field takes it, or the
  list should take it. Then a pending `g` and the table decide.
- `Command.all` is the table. Each command has an id, a title, a group, the
  keys that run it, a scope, whether it repeats while held, and an optional
  footer hint. The scope is `.anywhere`, `.rows(Set<RowKind>)` or
  `.when(predicate)`. One key can serve several commands as long as their
  row kinds differ: `h` snoozes a thread and sets a reminder on a pull
  request. A test makes sure no key runs two commands on the same kind of
  row.
- The same table feeds the router, the command menu (`Command.menu`, the
  commands that apply now), the keymap overlay and Settings
  (`Command.keymap`), and the footer (`Command.hints`). A new command is
  one line in the table.

## Where Baton sits

- **Views own their data.** Fragments sit beside the views that read
  them: the subject glyphs in `Rows/SubjectViews.swift`, the My PRs row in
  `Rows/PullRequestRow.swift`, and the peek in `Overlays/PeekView.swift`.
  Queries sit on the screens: `Panel/MyPullRequestsView.swift`. A view
  redraws when its own fields change, not when the inbox does.
- **The model's operations sit beside the model**, in `.graphql` files:
  `Graph/Subjects.graphql` and `Graph/PullRequestWrites.graphql`.
- **The subject store** keeps one handle per subject, retained while the
  thread is in the inbox. A notification names its subject by repository
  and number, so the first fetch goes through `repository(owner:name:)`.
  Later refreshes go through `nodes(ids:)` in batches into the same
  records.
- **Facts cross the boundary as values.** `SubjectFactsReading.swift`
  reads the facts fragments into plain `SubjectFacts`, so the classifier
  stays pure and never sees Baton.
- **Handles are shared by value.** The model asks for
  `MyPullRequestsQuery()` and gets the same handle as the view's `@Query`:
  one fetch and one cache, kept fresh from the model.
- **The image comes first.** At launch the inbox is classified from Baton's
  on-disk image before the network answers.
- **Writes are optimistic.** A mutation shows its typed optimistic response
  at once. GitHub's answer replaces it, and Baton takes it back if GitHub
  refuses. `WriteTests` plays GitHub to show all three.

When Caton needs something Baton does not have, the fix belongs in Baton;
Caton does not work around it.

## A press of `e`, end to end

1. The panel's key monitor turns the `NSEvent` into a `KeyPress` and calls
   `KeyRouter.handle`.
2. No overlay is up, and a thread is selected. The table matches `e` to
   `done`, whose scope covers threads, review requests, reminders and
   bundles.
3. `AppModel.done()` takes the targets from the panel (the checked rows,
   else the selection) and asks the session to dismiss them.
4. The session queues `done` for the thread's current activity with a
   5-second undo window and recomputes. A queued dismissal already hides
   the row, so the new snapshot fires `onChange`, the panel lays itself out
   again, the row is gone and the selection moves to the next one.
5. `z` within the window takes the batch out of the queue. Otherwise the
   dispatcher sends `DELETE /notifications/threads/{id}` (nothing in a dry
   run) and records the dismissal against that activity.
6. The thread stays out until GitHub reports activity newer than the
   dismissal. It then comes back with the reason it returned ("back: new
   comment by @alex").

## Tests

- `CatonCoreTests`: the classifier, projection, queue, local state, layout
  and search, all as pure functions.
- `CatonTests`:
  - `AppModelTests`: an `AppModel` signed in to a `.local` session.
  - `KeyTests`: keys through the router, built by hand.
  - `WriteTests`: a scripted GraphQL transport playing GitHub.
  - `ImageTests`: the launch from the image.
  - `SpeedTests`: keystrokes, search and reclassification at 1,000
    threads, each held to a time budget.
- Against a real account, run with `CATON_DRY_RUN=1` so nothing reaches
  GitHub.
