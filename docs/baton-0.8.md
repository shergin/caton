# Baton 0.8 in Caton

Caton depends on the published 0.8 series, with 0.8.0 locked in
`Package.resolved`. SwiftPM downloads the matching compiler artifact. The
build plugin produces generated Swift and `Baton.report.json` under
`.build/plugins/outputs/caton/Caton/destination/BatonPlugin/Generated/`.
The report lists Caton's operations and fragments and their compiled text;
it is not bundled into the app.

## Adopted

- GraphQL enums and mutation input objects are generated Swift types.
  Unknown enum values fall back conservatively in the classifier.
- `DateTime` and `URI` map to `Foundation.Date` and `Foundation.URL`.
  Invalid values remain optional instead of being parsed at each call site.
  Nullable lists use `Baton.List.empty` without copying into temporary arrays.
- The transport implements `send` and uses Baton's request encoding. Queries
  retry transient connection and 5xx failures twice with jittered backoff;
  mutations are sent once. Each HTTP attempt has a 15-second timeout. Both
  GraphQL and REST obey the same rate governor.
- Model handles keep `Retention` tokens; the store owns the release buffer.
  A session ends its environment before its image is reused or deleted.
  Signing out forgets the credential after that cleanup.
- `Observations` reads subject facts, review requests, and pull request
  standings. Classification, keyboard ordering, and reminders therefore
  follow commits from all operations, rather than selected fetch callbacks.
- My PRs declares a five-minute cache expiration and Peek one minute.
  Opening the panel revalidates retained queries. `fetch.failure` exposes a
  failed refresh beside usable cached data and a retry button.
- Mutation payloads use `@catch` so a partial GraphQL refusal cannot
  become a success toast. Nudge's optimistic timestamp lives in the client
  field `catonNudgedAt`, declared in `client-schema.graphql`. The server's
  timeline is untouched until its answer arrives; rejection removes the
  timestamp, and optimistic values never reach the disk image.
- `Environment.log` routes diagnostic events to macOS logging under
  `dev.caton.Caton`, category `GraphQL`. Debug builds add a Store tab to
  Settings using `BatonInspector`, including its export for fixture creation.
- Tests use `RecordedTransport`, `ScriptedTransport`, `wait(until:)`, and
  `commitPayload` for cached launch, late responses, optimistic writes,
  rollback, malformed scalar data, and changes arriving through other views.

The release also brings compact operation text, smaller generated plans,
bounded session keys, and persistence fixes automatically. Caton's existing
discovery by repository and number, followed by batched `nodes(ids:)`
refreshes, continues to use Baton's shared records.

## Deliberately unused

GitHub's endpoint does not provide the subscriptions, persisted document
registration, or incremental delivery these features require. GitHub node
IDs already supply identity, and Caton's per-account image should keep its
subjects and review searches for launch, so custom identity and transient
cache exclusions add no benefit. The release's later `@inline` compiler
work is still unreleased; facts continue to be read through typed lenses.
