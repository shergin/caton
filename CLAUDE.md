# Working in Caton

Caton is a demo app built on Baton (`../baton`). Read `PRD.md` for what it is
for; the research is in `research/`.

## Build and test

```sh
swift build
swift test
CATON_DRY_RUN=1 ./scripts/run.sh
```

Always run against a real account with `CATON_DRY_RUN=1` unless the user
asks otherwise: without it, verbs and rules change the account's
notifications on GitHub. Stop the app with `pkill -x Caton`.

## Layout

- `Sources/CatonCore`: Foundation only. The REST client, classifier, action
  queue, local state and inbox projection. Everything that decides what shows
  where lives here and is tested here.
- `Sources/Caton`: the app. `Graph/` holds Baton documents and the subject
  store, `Model/AppModel.swift` owns all state and every change to GitHub,
  `Views/` and `App/` are the panel and the AppKit shell.
- GraphQL lives beside the code that reads it (`@Fragment`, `@Query`); the
  schema is `schema.docs.graphql` at the root with `baton.json`.

## Conventions

- Swift 6 language mode, strict concurrency; UI and model on the main actor.
- The notifications feed is REST (GitHub has no GraphQL for it); subject
  state is GraphQL through Baton. Do not fetch subject state over REST.
- Classification is a pure function in CatonCore. A new rule is a case in
  `Rule`, a branch in `Classifier`, and a test.
- Tests use Swift Testing and are named for the behaviour they prove.
- Improvements Baton needs go to `../baton/notes/`, not into Baton's code.
- Commit messages: imperative, short subject, no attribution lines.
