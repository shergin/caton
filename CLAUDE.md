# Working in Caton

Caton is a demo app built on Baton 0.15, pinned by `Package.resolved`. Read `PRD.md` for what it is
for. The research behind it is kept locally in `research/`, outside git.

## Build and test

```sh
swift build
swift test
CATON_DRY_RUN=1 ./scripts/run.sh
```

Always run against a real account with `CATON_DRY_RUN=1` unless the user
asks otherwise: without it, verbs and rules change the account's
notifications on GitHub. Stop the dev build with
`pkill -f .build/debug/Caton`; `pkill -x Caton` would also quit the
installed app.

Debug builds keep their own files (`~/Library/Application Support/Caton
Debug`, `~/Library/Caches/dev.caton.Caton.debug`), apart from the installed
app's `Caton` folders, so a dry run never leaves marks the installed app
trusts. They still hold the user's real dev state: for layout checks that
don't need the account, use `CATON_PRACTICE=1` with `CATON_SNAPSHOT`;
practice must never reach that file (`persisted()` saves the inbox set
aside).

## Layout

- `Sources/CatonCore`: Foundation only. The REST client, classifier, action
  queue, local state and inbox projection. Everything that decides what shows
  where lives here and is tested here.
- `Sources/Caton`: the app. `ARCHITECTURE.md` is the map. In short:
  `Model/` has `Session` (one inbox: feed, local state, queue, writes),
  `Accounts` (sign-in, building sessions), `Panel` (where the user is, and
  the laid-out list) and `AppModel` (the root and the commands); `Keys/`
  has the command table every key, menu and hint reads; `Graph/` holds
  Baton documents and the subject store; `Views/` is split into `Panel/`,
  `Rows/`, `Overlays/` and `Settings/`; `App/` is the AppKit shell.
- A new command is a line in `Command.all` with the row kinds it applies
  to; a new overlay handles its own keys in a `handle(_:model:)` beside
  its view.
- GraphQL lives beside the code that reads it: `@Fragment` and `@Query` on
  views, `.graphql` files beside model code (`Graph/Subjects.graphql`). A
  model that needs a view's query asks for the same operation value and
  shares its handle. The schema is `schema.docs.graphql` at the root with
  `baton.json`.
- SwiftPM downloads Baton's matching prebuilt compiler. No sibling checkout
  or Rust build is required. The plugin regenerates code when its compiler,
  config, schema extensions, or documents change. `swift package resolve`
  restores the versions in the lockfile.
- `baton.json` maps GraphQL dates and URLs to Foundation types and includes
  `client-schema.graphql`, whose nudge timestamp exists only in an optimistic
  layer. Retain model handles with `Retention` tokens and end the environment
  before deleting its image or opening another store on the same file.
- Tests use `BatonTesting` fixtures and held mutations. Changes to GraphQL
  facts are observed through `Observations`; do not add fetch callbacks to
  keep classification or reminders in sync.

## Conventions

- Swift 6 language mode, strict concurrency; UI and model on the main actor.
- The notifications feed is REST (GitHub has no GraphQL for it); subject
  state is GraphQL through Baton. Do not fetch subject state over REST.
- Classification is a pure function in CatonCore. A new rule is a case in
  `Rule`, a branch in `Classifier`, and a test.
- Tests use Swift Testing and are named for the behaviour they prove.
- Improvements Baton needs go to `../baton/notes/`, not into Baton's code.
- Commit messages: imperative, short subject, no attribution lines.
