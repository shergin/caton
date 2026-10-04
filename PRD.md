# Caton: Product Requirements Document

| | |
|---|---|
| **Product** | Caton, a GitHub "needs-me" inbox for the macOS menu bar that clears itself |
| **Doc type** | PRD, v0.2 (supersedes the Octodot-derived draft) |
| **Date** | 2026-10-03 |
| **Status** | Draft. Demo app; scope is opinionated on purpose. Build started 2026-10-03 on Baton; see section 17. |
| **Inputs** | An Octodot teardown, a landscape report and research notes, kept locally in `research/` and not published |

---

## 1. TL;DR

GitHub notifies you about **events**. What you care about is **what needs you**. On a busy team, fewer than one in ten notifications needs any action. The rest is team fan-out, bots, AI reviewers, CI, drafts, and threads that were merged hours ago.

**Caton is a native menu-bar inbox that joins every GitHub notification to the live state of its pull request or issue, and to who it's actually aimed at.** It clears what no longer needs anyone, files the rest into four splits (**Needs me · Team · Following · Feed**), and leaves one keystroke per item for everything that's left.

**The promise:** *the number in your menu bar equals the number of things waiting on you.*

Octodot made triage fast. Caton's goal is to make most of it unnecessary, and to make the rest fast.

---

## 2. Problem

1. **GitHub notifies on events, not on state or ownership.** One developer's month-long audit found 28 of 317 notifications (8.8%) needed them. A merged PR, a team-wide review request, and a Dependabot bump all look the same as a direct ask.
2. **The top requests have gone unanswered for four or more years.** None of these were answered as of 2026-10-03:

   | GitHub Community request | Upvotes |
   |---|---|
   | Filter notifications by PR state (open/closed/merged) | 630 |
   | Disable team-mention notifications | 452 |
   | CODEOWNERS without notifying the whole team | 388 |
   | Mute bots | 353 |
   | Silence draft PRs | 341 |
   | Snooze | ~27 |

3. **GitHub now runs two inboxes that share no state.** The notifications inbox is event-based: four shortcuts, no snooze, no negative filters, and Done comes back on new activity. The new PR dashboard at github.com/pulls (GA 2026-07-09) is state-based. It separates direct from team review requests, but it can't clear or unsubscribe a notification thread.
4. **AI has increased the volume.** More than one in five reviews on GitHub now involve an agent. Agent-authored PRs wait 17.6 h for pickup (P75) vs 3.4 h for unassisted ones. AI review comments drown out human pings.
5. **Ambient presence is missing on desktop.** Push exists only in GitHub Mobile. The web inbox is a tab you have to remember to visit.

The job across every segment: **never miss what is aimed at me, and never see what isn't.**

---

## 3. Landscape and positioning

A basic native notifier is now cheap to build: there were a dozen hobby launches in 2026. So **speed is the minimum, not the product**. What lasts is the **classification layer**: the join of GitHub's event stream to PR state, actor type, and ownership, which GitHub has left split across two surfaces.

| Category | Representative | Their center of gravity | Caton's stance |
|---|---|---|---|
| Cross-platform client | Gitify (5.4k stars, Electron, 6 forges) | Breadth: forges, OSes, filters; keys navigate, not triage | Depth on GitHub's thread, macOS only, keyboard-complete and state-aware |
| Native PR tracker | Trailer | Watched-repo PR tracking behind a big rule system; classic PAT | Mirror GitHub's inbox; ship four good default rules, not a preferences maze |
| Curated feed | Neat (closed source) | "Only what matters" feed | Same promise, with rules you can inspect and undo |
| Reference app | Octodot | Fastest manual triage | Less triage: splits, auto-clean, snooze, undo, device-flow sign-in |
| GitHub web inbox | github.com/notifications | Synced states, weak filters, 4 shortcuts | Same synced states plus state, actor, and ownership context, full keyboard, desktop presence |
| GitHub PR dashboard | github.com/pulls | PR-state sections, direct vs team, j/k, web only | Borrow its taxonomy to classify threads; add thread actions and the menu bar |
| GitHub Mobile | iOS/Android | Push for 4 event types, working hours | Desktop counterpart: needs-me banners with quiet hours |
| Web inbox | Octobox | Server + Gmail keys; paid for private repos | Same model, no server, tokens never leave the Mac |
| Team PR platforms | Graphite, Linear Reviews | GitHub App mirrors of PRs, paid seats | A personal layer that complements them and can clear threads they can't touch |
| Terminal | gh-dash (notifications since 2026-01) | Query sections, Vim keys | Same key vocabulary in an always-available surface |
| Launchers | Raycast GitHub (208k installs) | Search-and-act; 15-min menu-bar refresh | A live inbox built for triage, not lookup |

---

## 4. Users

| Persona | Who | Their failure mode | What Caton gives them |
|---|---|---|---|
| **The reviewer on a busy team** (primary) | Engineer in an org with CODEOWNERS, team review requests, AI reviewers, coding agents. Dozens to hundreds of notifications a day. | Misses a **direct** review request buried in team fan-out and bot noise. | A Needs me count they can trust; team requests set apart; merged/closed and bot noise cleared automatically. |
| **The OSS maintainer** (secondary) | Watches many repos, triages in scheduled sessions (15–45 min each morning). | Notification bankruptcy; AI-generated contributions from untrusted authors. | Repo bundles, bulk "get me to zero", repo mute, bot bundles, actor badges. |
| **The keyboard purist** (design anchor) | Lives in Vim, gh-dash, Raycast. | Mouse-only tools; web inbox has 4 shortcuts. | Every verb on a key, Cmd+K that teaches shortcuts, <100 ms everything. |

**Not for:** people who want to review or reply inside the app, managers who want team analytics, multi-forge users, and (in this demo) GitHub Enterprise users.

---

## 5. Jobs to be done

1. *When a colleague asks me for a review,* I want it to stand out from everything else, *so I never block them by accident.*
2. *When I glance at the menu bar,* I want a number I can trust, *so I can decide whether to switch context right now.*
3. *When a thread no longer needs anyone (merged, closed, bot chatter),* I want it gone without my involvement, *and I want to see that it was cleared and why.*
4. *When something needs me but not now,* I want to snooze it until a time **or** until something new happens, whichever comes first.
5. *When I dismiss something and it comes back,* I want to know why it's back.
6. *When I triage,* I want one key per decision and undo instead of confirmation dialogs.
7. *Whatever I do here,* I want it reflected on github.com, so I'm not maintaining two inboxes.

---

## 6. Product principles

1. **Needs-me first.** The menu bar count is a contract: it counts only items that need *you*.
2. **State over events.** Every row is joined to live subject state (merged/closed/draft, CI, review decision), actor type (human, bot, AI reviewer, agent), and target (me, my team, watching).
3. **Explicit resurfacing.** Every verb states when the item comes back, and a returning item says why.
4. **Rules you can see.** A few default auto-clean rules, each with a toggle, logged in a visible **Cleared** list. No opaque AI ranking that reorders or hides items.
5. **Undo, not confirm.** Every action, including rule actions and bulk clears, can be undone within a grace window.
6. **Keyboard-complete, mouse-friendly.** Every action has a key. Cmd+K lists all actions with their shortcuts. Mouse paths exist for everything.
7. **A latency budget, not an aspiration.** Hotkey to interactive panel in <100 ms from cache. Keystroke to rendered result in <50 ms.
8. **Quiet by default.** Banners only for Needs me, deduplicated, capped, silent during quiet hours. Caton batches and suppresses more than it alerts.
9. **GitHub is the source of truth where an API exists; local where it doesn't.** Done, read, and unsubscribe sync to GitHub. Snooze, Later, rules, and mutes are local, and the UI says so.
10. **Pure client, polite citizen.** No server. Tokens stay in the Keychain. Conditional polling and batched GraphQL. Bulk mutations are paced.

---

## 7. Experience overview

```
 Menu bar:  [glyph 3]   <- Needs me count (dot-only option). Click or global hotkey (default Cmd+').
                |
                v
+------------------------------------------------------------------+
| Caton                                              (spinner) [⌘K] |
| [ Needs me 3 ]   Team 12    Following 8    Feed 41                 |  <- splits, Tab / Shift-Tab
|------------------------------------------------------------------|
| (PR) acme/web#4521                        Review · you    [CI x]  |
|  *   Fix hydration mismatch in checkout     (av) 2h · waiting 26h |
| (PR) acme/api#902 · back: new review       Changes requested      |
|  *   Add rate limiter to /search                     (av) 15m     |
| (Is) acme/web#4388                                   Mentioned    |
|  *   Middleware drops search params                   (av) 1h     |
|------------------------------------------------------------------|
|        [ toast: Done acme/web#4521 · z to undo ]                  |
| e done  h snooze  u unsub  ⏎ open  tab split  ⌘K actions  ? keys  |
+------------------------------------------------------------------+
```

- Floating, non-activating panel (about 400 x 560 pt). It appears on the active Space (including full-screen apps), closes on outside click or Esc, and keeps its state (selection, split, search) when it closes.
- Secondary views (not splits): **Snoozed**, **Later**, **Cleared** (rule and bulk log), reachable with `g s`, `g l`, `g c` or Cmd+K.

---

## 8. Triage model

### 8.1 Splits

A thread lands in exactly one split. Splits are computed from the notification `reason` plus enrichment (subject state, review requests, latest reviews, author type). Read/unread is an **attribute** shown as a dimmed row and a filter (`a`), not a view.

| Split | What lands there | Counted in menu bar | Banners | Default treatment |
|---|---|---|---|---|
| **Needs me** | Direct review requests; @mentions; assignments; deployment approvals (`approval_requested`); security alerts; **your own open PRs that came back to you** (changes requested, failing checks, new review); orphan direct review requests found by search (8.3) | Yes | Yes | Never auto-cleared |
| **Team** | Review requests that reach you only through a team; `team_mention` | No (panel count only) | No | Auto-Done when the subject merges or closes |
| **Following** | Threads you authored, commented on, or subscribed to manually (`author`, `comment`, `manual`, `state_change`) with nothing asked of you; review requests you've already reviewed (until re-requested) | No | No | Auto-Done when the subject merges or closes |
| **Feed** | Watched-repo activity (`subscribed`), `ci_activity`, non-issue/PR types (releases, discussions, commits, invitations, …), bot-authored PRs, drafts that don't request you | No | No | Bundled by repo and by bot; bulk-clearable via "Get me to zero" |

**Classification precedence:** auto-clean rules run first (8.4). Then Needs me > Team > Following > Feed. A thread can move between splits as its state changes (for example, a re-request moves a Following item back to Needs me).

**Direct vs team heuristic** (GitHub exposes no field for this):
- `reason = review_requested` **and** `reviewRequests` names the viewer as a User → **direct** (Needs me).
- The viewer already appears in `latestReviews` and hasn't been re-requested → **reviewed** (Following).
- Otherwise → **team** (Team).
- Must be validated against github.com/pulls' own direct/team split (Spike S3).

**Actor type** (shown as a badge on the avatar): human · bot (`[bot]` login or `Bot` type; known list: Dependabot, Renovate, …) · AI reviewer (Copilot, CodeRabbit, …) · agent (PRs authored by coding agents). The list of known bots and AIs is user-editable.

### 8.2 Verbs and resurfacing

| Verb | Key | GitHub effect | When it comes back |
|---|---|---|---|
| **Open** | Return, `o` | Mark read, sent immediately; opens the browser | Stays (dimmed) until another verb applies |
| **Done** | `e`, `d` | `DELETE /notifications/threads/{id}` after the undo grace window | On any new activity on the thread, with a "back: …" note |
| **Snooze** | `h` | None (local) | At the chosen time **or** on new activity that would place it in Needs me, whichever comes first. Variant: "only if nothing happened" (follow-up reminders on your own PRs) |
| **Unsubscribe** | `u` | REST `DELETE …/subscription`, then Done (same as GitHub web Unsubscribe) | Only if you're @mentioned, team-mentioned, or asked for review |
| **Ignore thread** | Cmd+K only | GraphQL `updateSubscription(IGNORED)`, then Done | Never ("The User is never notified"). Worded explicitly in the UI. |
| **Later** | `b` | None (local list; GitHub's Saved has no API) | Never on its own; optional reminder |
| **Mark read** | `m` | `PATCH /notifications/threads/{id}` | n/a (there's no mark-unread endpoint) |
| **Mute repo** | Cmd+K | None (local rule R4) | Unmute in Settings or Cleared |
| **Select / bulk** | `x`, then any verb | One paced call per thread | Same rules as the verb applied |
| **Undo** | `z`, Cmd+Z | Cancels the queued call(s) | n/a |
| **Copy link** | `y` | None | n/a |
| **Peek** | `p` (P1) | None (does **not** mark read) | n/a |

**Resurfacing note.** When a dismissed or snoozed item returns, line 1 carries a short reason: "back: new comment", "back: re-requested", "back: checks failed", "back: snooze ended".

### 8.3 Orphan review requests

Users report review requests that are visible in search but missing from notifications. On panel open and every few minutes (not on every poll), Caton runs one GraphQL search for open PRs that **directly** request the viewer's review. Results without a matching notification thread appear in Needs me, marked "no notification". For these items, Done hides them locally until the PR updates, since there's no thread to delete. Cost and query accuracy are Spike S4.

### 8.4 Auto-clean rules (default on, each toggleable)

| Rule | Condition | Action |
|---|---|---|
| **R1 Merged/closed** | Subject merged or closed, and thread is in Team, Following, or Feed | Done (synced to GitHub) |
| **R2 Drafts** | Draft PR that doesn't directly request you | Route to Feed |
| **R3 Bot PRs** | PR authored by a bot (Dependabot, Renovate, …) | Route to Feed, bundled per bot |
| **R4 Muted repos** | Repo is on the local mute list | Done on arrival |

- Every rule action is written to the **Cleared** log with the rule name, the thread, and the time. It can be undone during the grace window. After that, the log keeps a link to GitHub for 7 days.
- **Rule clears stay on this Mac until the user opts in** ("Mark rule-cleared threads done on GitHub"). A first sync can match hundreds of threads, and marking them done on GitHub is not undoable after dispatch, so the default is local; the onboarding summary (OB-02) is where the user turns it on.
- Rules never touch Needs me.
- Muting bot *comments* on human PRs needs the latest comment's author (an extra fetch per thread). It's a should-have pending a cost measurement.

### 8.5 Inbox membership

Caton mirrors GitHub's inbox, not watched repos. A thread is in Caton when it's **unread**, or **read but not done** within a recent window (reference: 14 days of local reads plus recently read threads from the server). It's removed when it's Done (locally suppressed until `updated_at` advances, because done threads can still appear in `?all=true`), unsubscribed, rule-cleared, snoozed, or moved to Later. GitHub keeps 3 months of inbox history. Anything older exists only in Caton's local store.

---

## 9. Functional requirements

Priority: **P0** = demo must-have · **P1** = should-have · **P2** = later.

### 9.1 Menu bar and entry points

| ID | Requirement | Pri |
|---|---|---|
| MB-01 | Menu-bar-only agent app (no Dock icon). | P0 |
| MB-02 | Status item shows an original glyph plus the **Needs me count** when >0. A dot-only option is available. Signed-out and error states are visually distinct. | P0 |
| MB-03 | The count reflects pending local actions, rule clears, snoozes, and mutes immediately, so it always matches the Needs me split. | P0 |
| MB-04 | Tooltip and VoiceOver: "3 need you · 12 team · 8 following · 41 feed". | P1 |
| MB-05 | Left-click toggles the panel. Right-click menu: Settings…, Check for Updates…, Quit. | P0 |
| MB-06 | Configurable global hotkey (default Cmd+'). Must include Cmd, Option, or Control. Shows an actionable error if registration fails. This is the guaranteed entry point, since macOS 26 lets users hide menu-bar extras. | P0 |
| MB-07 | Second hotkey that opens straight into Needs me with the top item selected. | P2 |

### 9.2 Panel

| ID | Requirement | Pri |
|---|---|---|
| PA-01 | Opens from the local cache in <100 ms with list focus, then refreshes in place (a spinner in the header, never a blank list). | P0 |
| PA-02 | Header: split tabs with live counts; the current split is highlighted. | P0 |
| PA-03 | Within a split, rows are grouped by repo (toggle `s`) with stable group order: repos don't reshuffle while you work. Feed collapses bundles (per repo, per bot) that expand inline. | P0 |
| PA-04 | Empty states per split: Needs me shows "Nothing needs you", and the others say what got cleared ("12 cleared by rules today, view"). | P0 |
| PA-05 | Status strip shows one message at a time, by priority: error > rate-limit cooldown > warning > update. | P0 |
| PA-06 | Toasts confirm every action with an undo hint ("Done acme/web#4521 · z to undo", "Cleared 37 items · z to undo"). They stack up to 3 and auto-dismiss. | P0 |
| PA-07 | Footer: context-sensitive key hints and a Cmd+K button. | P0 |
| PA-08 | Detach the panel into a resizable window. | P2 |

### 9.3 Row

| ID | Element | Pri |
|---|---|---|
| RW-01 | Unread dot; read rows are dimmed. | P0 |
| RW-02 | Type and state icon: PR open/draft/merged/closed/in merge queue; issue open/completed/not planned. Neutral placeholder until enriched. | P0 |
| RW-03 | Line 1: `owner/repo#123`, plus a "back: …" resurfacing note when applicable. | P0 |
| RW-04 | Line 2: title (bold when unread). | P0 |
| RW-05 | Ownership badge: "Review · you", "Review · team", "Mentioned", "Assigned", "Your PR · changes requested", "Ready to merge" (P1). | P0 |
| RW-06 | PR signals: CI rollup (pass/fail/pending) and review decision (approved/changes requested). | P0 |
| RW-07 | Actor avatar with bot / AI / agent badge. | P0 |
| RW-08 | Age ("2h"), plus an aging cue on Needs me items ("waiting 26h"). | P0 / P1 |
| RW-09 | Hover: Done, Snooze, and Unsubscribe buttons replace the trailing metadata (no layout shift). Hovering the icon turns it into a select checkbox. | P1 |
| RW-10 | Click = Open. Full VoiceOver label: title, repo#, ownership, state, actor, age, read state. | P0 |

### 9.4 Actions and the action queue

| ID | Requirement | Pri |
|---|---|---|
| AC-01 | All verbs in 8.2 are available by key, by Cmd+K, and (for primary verbs) on hover. | P0 |
| AC-02 | **Optimistic:** the UI applies the action instantly and **selection auto-advances** to the next item. | P0 |
| AC-03 | **Undo grace window:** mutations are held for a few seconds (reference: 5 s) before dispatch. `z` cancels them exactly. Open's mark-read skips the hold. After dispatch, undo is best-effort (local restore only), and the toast says so. | P0 |
| AC-04 | **Persisted queue:** queued and in-flight actions survive panel close, refresh, quit (bounded drain), crash, and relaunch. | P0 |
| AC-05 | **Paced dispatch:** serial requests, ≥1 s apart when bulk, with backoff on secondary limits. 300 Dones drain in about 5 min in the background while the UI already shows them gone. | P0 |
| AC-06 | **Precise dismissal:** done/unsubscribe applies to the activity the user saw (thread ID + `updated_at`). New activity resurfaces the thread. | P0 |
| AC-07 | **Failure rollback:** the row reappears in place with a specific error. A partial unsubscribe (subscription succeeded, done failed) is reported as such. 401 → re-auth. | P0 |
| AC-08 | **No double-fire:** single-shot keys fire on key-up, never auto-repeat, and are deduplicated. Navigation keys repeat. | P0 |
| AC-09 | **Get me to zero** (Cmd+K): Done everything in Feed and/or everything older than N days in the current split. Shows a count preview, one toast, and undo. | P0 |
| AC-10 | Bulk select with `x`; any verb then applies to all selected rows, in visible order, with one aggregated toast. | P0 |

### 9.5 Search and filters

| ID | Requirement | Pri |
|---|---|---|
| SE-01 | `/` live text filter over title and repo within the current split. Return/Tab keeps the filter; Esc clears it. | P0 |
| SE-02 | `a` toggles "unread only". | P0 |
| SE-03 | Structured qualifiers with negation: `repo:`, `-repo:`, `org:`, `reason:`, `is:pr`, `is:issue`, `is:draft`, `author:`, `ci:failing`, `state:open`. | P1 |
| SE-04 | Saved searches as custom splits. | P2 |

### 9.6 Alerts

| ID | Requirement | Pri |
|---|---|---|
| AL-01 | macOS banners **only for new Needs me items**, deduplicated by thread, capped per poll (reference: 3, then "and N more"). | P0 |
| AL-02 | Quiet hours (default off outside 9:00–19:00 on weekdays, user-configurable). Respects macOS Focus. | P0 |
| AL-03 | Clicking a banner opens the panel with that item selected (not the browser). | P0 |
| AL-04 | Optional morning digest banner: "4 need you, 37 cleared overnight". | P2 |

### 9.7 Sync

| ID | Requirement | Pri |
|---|---|---|
| SY-01 | Poll page 1 of `/notifications` with `If-Modified-Since` at `X-Poll-Interval` (60 s observed). A 304 costs nothing against the primary rate limit. | P0 |
| SY-02 | On a 200, fetch further pages serially at **50 per page** (the API cap). Use `since` for deltas. | P0 |
| SY-03 | Full reconciliation on panel open and about every 10 min, because `since` can't see threads marked done or read elsewhere. | P0 |
| SY-04 | Read-not-done window fetched with `all=true` (bounded), merged with locally tracked reads. | P0 |
| SY-05 | A single client-wide rate governor honors `Retry-After`, `X-RateLimit-Reset`, and low `x-ratelimit-remaining`. It pauses feed, enrichment, search, and actions together, and the UI shows the cooldown. | P0 |
| SY-06 | Newer loads supersede older ones. Stale responses never overwrite fresher data. Account switches discard in-flight work. | P0 |
| SY-07 | Pin the REST API version header. | P0 |
| SY-08 | Network failure keeps the last good data and shows an error; the list never blanks. | P0 |

### 9.8 Enrichment

| ID | Requirement | Pri |
|---|---|---|
| EN-01 | Enrich **every thread whose `updated_at` changed**, not just visible rows, because splits and rules depend on state. | P0 |
| EN-02 | GraphQL batches of 50 aliases (about 1 point per batch). PR fields: `state`, `isDraft`, `isInMergeQueue`, `mergedAt`, `reviewDecision`, `reviewRequests`, `latestReviews`, `statusCheckRollup.state`, author `login`/`__typename`/`avatarUrl`. Issue fields: `state`, `stateReason`, author. | P0 |
| EN-03 | Errors are handled per alias (NOT_FOUND doesn't fail the batch). Treat `mergeable: UNKNOWN` as unknown. Targeted REST fallback only for unresolved subjects. | P0 |
| EN-04 | Re-check open subjects periodically and on panel open, so merges, closes, and CI results show up without new notification activity. | P0 |
| EN-05 | Persist enrichment with the thread for instant cold starts. | P0 |

### 9.9 Authentication and account

| ID | Requirement | Pri |
|---|---|---|
| AU-01 | **Sign in with GitHub via OAuth App device flow.** Caton's client ID is embedded and no secret is shipped. The panel shows the code with a Copy button and opens the browser. | P0 |
| AU-02 | Scope modes: **Full** (`notifications repo`, for private-repo state and CI) and **Lite** (`notifications public_repo`; private subjects show neutral state). Each explains the trade-off in one sentence. | P1 |
| AU-03 | Import an existing token from the GitHub CLI (`gh auth token`) when present. | P1 |
| AU-04 | Classic PAT paste as an advanced fallback, with scope validation that names any missing scopes. | P0 |
| AU-05 | Token stored only in the Keychain. Per-account local store. Sign-out wipes local state. A 401 prompts re-auth. | P0 |
| AU-06 | Fine-grained PATs and GitHub App tokens are **not supported**, because the notifications API rejects them. Settings states this plainly. | P0 |
| AU-07 | Multiple accounts and GitHub Enterprise Server / GHE.com: designed for in the data model, not shipped in the demo. | P2 |

### 9.10 Onboarding and learnability

| ID | Requirement | Pri |
|---|---|---|
| OB-01 | First launch opens the panel on the sign-in screen. | P0 |
| OB-02 | After the first sync, a one-screen summary: "Of 214 notifications, 6 need you. 151 were cleared by rules. Here's why." | P1 |
| OB-03 | A three-key tip overlay that teaches only `e` (done), `h` (snooze), and Tab (next split). | P1 |
| OB-04 | Cmd+K action panel that runs any action and shows its shortcut; a `?` overlay with the full keymap. | P0 |
| OB-05 | Practice inbox with synthetic items. | P2 |

### 9.11 Settings

| Tab | Contents | Pri |
|---|---|---|
| General | Launch at login, appearance, menu-bar display (count/dot), global hotkey | P0 |
| Splits & Rules | Toggle R1–R4, muted repos, bot/AI lists, read-window length | P0 |
| Alerts | Banners on/off, quiet hours, per-poll cap | P0 |
| Account | Sign-in method, scope mode, signed-in user, sign out, token-type explainer | P0 |
| Shortcuts | Read-only keymap reference (remapping P2) | P1 |
| About | Version, updates, acknowledgements | P1 |

### 9.12 Distribution

| ID | Requirement | Pri |
|---|---|---|
| UP-01 | Developer ID–signed, notarized build. Homebrew's main cask repository only takes apps that pass Gatekeeper (since 2026-09-01). | P1 |
| UP-02 | Distribution as a Homebrew cask; `brew upgrade` installs updates. No in-app updater: the app checks GitHub Releases and shows the upgrade command when a release is out. | P1 |
| UP-03 | Stay App Store–compatible: sandbox-safe hotkey, network-client entitlement only, Keychain. Not submitted in the demo. | P2 |

---

## 10. Keymap

| Group | Action | Keys |
|---|---|---|
| Move | Down / up | `j` / `k`, Down / Up |
| | Page down / up | Space, `Ctrl-F` / `Ctrl-B`, Page Down / Page Up |
| | Half page | `Ctrl-D` / `Ctrl-U` |
| | Top / bottom | `gg` / `G`, Cmd+Up / Cmd+Down |
| | Next / previous split | Tab / Shift-Tab |
| | Jump to split | `1` `2` `3` `4` |
| | Go to Snoozed / Later / Cleared | `g s` / `g l` / `g c` |
| Act | Open (marks read) | Return, `o` |
| | Done | `e`, `d` |
| | Snooze | `h` |
| | Unsubscribe | `u` |
| | Later | `b` |
| | Mark read | `m` |
| | Select for bulk | `x` |
| | Undo | `z`, Cmd+Z |
| | Copy link | `y` |
| | Peek (P1) | `p` |
| View | Search | `/` (Return/Tab keep, Esc clear) |
| | Unread only | `a` |
| | Group by repo | `s` |
| | Refresh | `r` |
| | Action panel / keymap | Cmd+K / `?` |
| | Close | Esc |

The vocabulary follows gh-dash (`d` `m` `u` `b` `o`) and Superhuman/Linear (`e` done, `h` snooze, `z` undo), so terminal users and inbox-zero users both feel at home.

---

## 11. Non-functional requirements

| Area | Requirement |
|---|---|
| **Latency** | Hotkey to interactive <100 ms (cache). Keystroke to render <50 ms at 1,000 items. Keystrokes typed during a re-render are queued, never dropped. |
| **API budget** | Idle: about 0 primary-limit cost (304s). 500 unread with constant churn: ≤12% of the 5,000/h REST budget. Enrichment: ≤5% of the GraphQL budget. The budget is shared with `gh` and IDEs, so leave headroom. |
| **Reliability** | Zero lost actions. No "came back" bugs without new activity. No UI stalls during rapid bulk actions. |
| **Correctness** | Synced states (done, read, unsubscribe) converge with github.com within one poll interval plus the dispatch delay. |
| **Security** | Keychain only; HTTPS to `api.github.com` / `github.com` only. Reject untrusted pagination or subject URLs. Hardened runtime. |
| **Privacy** | No server, no telemetry. Optional local-only stats ("this week: 312 cleared by rules, 41 by you"). |
| **Accessibility** | Full VoiceOver coverage; keyboard-only is the primary path; respects Reduce Motion and the system appearance. |
| **Platform** | macOS 26+ (Baton's floor), Apple silicon and Intel. |

**API budget (from documented limits and first-hand tests, 2026-10-03):**

| Workload | Primary REST cost / h | Share of 5,000 |
|---|---|---|
| Poll every 60 s, nothing changes (304) | 0 counted | 0% |
| Changes every poll, ≤50 unread | 60 | 1.2% |
| 200 unread re-fetched on change | 240 | 4.8% |
| 500 unread re-fetched on change | 600 | 12% |
| Bulk Done of 300 threads | 300 (+1,500 secondary points, ~5 min paced) | 6% |
| GraphQL enrichment of 200 threads every minute | ~240 GraphQL points (separate bucket) | ~5% of GraphQL |

---

## 12. Architecture

**Pure native client. No server, no webhooks.** There's no inbox webhook, and a relay would be bound by the same per-user poll interval and rate limit. It would add risk without adding freshness.

```
+------------------------------------------------------------------+
| Shell (AppKit)   NSStatusItem · non-activating NSPanel · Settings |
|                  global hotkey (KeyboardShortcuts / Carbon)       |
+------------------------------------------------------------------+
| UI (SwiftUI)     Panel, splits, rows, Cmd+K, toasts, onboarding   |
+------------------------------------------------------------------+
| App model        @MainActor @Observable InboxModel: split         |
|                  projections, selection, counts                   |
+------------------------------------------------------------------+
| Domain (pure)    Classifier · RuleEngine · ResurfacingPolicy      |  <- the product
+------------------------------------------------------------------+
| Stores           Baton image (SQLite): subject records;          |
|                  JSON document: threads, activity keys,           |
|                  snoozes, Later, mutes, Cleared log, action queue |
+------------------------------------------------------------------+
| Sync             FeedSyncer (REST poll) · SubjectStore (Baton) ·  |
|                  ReviewRequestSearcher · ActionDispatcher (paced) |
+------------------------------------------------------------------+
| GitHubClient     actor; REST + GraphQL; conditional requests;     |
|                  rate governor; version pin; trusted-URL checks   |
+------------------------------------------------------------------+
| Auth             Device flow · gh import · PAT · Keychain         |
+------------------------------------------------------------------+
```

| Layer | Decision | Why |
|---|---|---|
| Shell | Swift 6; AppKit `NSStatusItem` + non-activating `NSPanel` hosting SwiftUI; **not** `MenuBarExtra` | `MenuBarExtra` can't be dismissed or driven programmatically |
| Hotkey | KeyboardShortcuts (Carbon) | Sandbox-safe; the only entry point Caton can count on |
| Auth | OAuth App device flow, `gh` import, PAT; Keychain; no refresh logic | Only classic-scope tokens read notifications; OAuth App tokens work and don't expire |
| Sync | Conditional poll of page 1 → serial pages at 50 → `since` deltas + periodic full reconcile | 304s are free; page cap is 50; `since` misses work done elsewhere |
| Store | Subject records in Baton's store and its SQLite image, per account; threads, local state and the queue in one JSON document | Instant cold start (the image hydrates subjects before the network); local-only states; 3-month server retention |
| Domain | `classify(thread, subject, viewer, settings) -> (split, ruleActions, resurfaceNote)` as a pure, table-tested function | This layer is the product; the shell is a commodity |
| Actions | Optimistic projection over a persisted queue; undo grace window; paced serial dispatch; local done ledger keyed on thread ID + `updated_at` | No API returns a done thread to the inbox; secondary limits; done threads can reappear in `all=true` |
| Enrichment | Through Baton: one handle per subject, first fetched by `repository(owner:name:) { pullRequest(number:) }`, then refreshed by `nodes(ids:)` in batches of 50 into the same records; rows read fragments, the classifier reads a facts fragment | Operations are fixed at build time, so aliases cannot vary per inbox; a node id is learned once per subject |
| Alerts | `UNUserNotificationCenter`, Needs me only, dedupe + cap + quiet hours | Less interruption, not more |
| Concurrency | `actor` client; UUID request IDs checked after every `await`; cancellation through pagination | Lessons from Octodot's race-fix history |
| Testing | Swift Testing; stubbed `HTTPClient`; fixture-driven classifier tables; deterministic clocks; `CATON_DRY_RUN=1` against a real account | Most risk is in sync and state, not UI |

**Core data model (sketch)**

| Entity | Key fields |
|---|---|
| `Thread` | id, repo, subjectType, subjectNumber, title, reason, unread, updatedAt, lastReadAt, webURL |
| `Subject` | state, isDraft, inMergeQueue, reviewDecision, ciRollup, author{login, kind}, reviewRequests[], latestReviews[], fetchedAt |
| `Classification` | split, ownership badge, ruleApplied?, resurfaceNote? |
| `LocalState` | doneLedger(threadId → activityKey), snoozes(threadId, until, wakeOnActivity, onlyIfQuiet), later(threadId, remindAt?), mutedRepos, clearedLog |
| `QueuedAction` | id, threadId, verb, activityKey, notBefore, attempts, status |

---

## 13. Non-goals

| Non-goal | Why |
|---|---|
| Replying, reviewing, approving, merging in-app | The browser is where work happens |
| A PR dashboard beyond Needs me | GitHub /pulls and Graphite own it |
| Other forges, Windows, Linux, mobile | Gitify's lane |
| Servers, relays, webhooks, cross-device sync | No inbox webhook; a relay can't beat client polling |
| Fine-grained PAT or GitHub App sign-in | The API rejects those tokens |
| Mirroring GitHub's Saved, custom filters, sort order | No API |
| AI ranking that reorders or hides items | Trust; AI-summary demand is ~7 upvotes. Labels, yes; silent reordering, no |
| Team analytics, review SLAs | Different buyer (LinearB, Faros) |
| GHE / multiple accounts in the demo | Each needs PAT or customer-registered OAuth App; designed for, not shipped |

---

## 14. How we'll know the thesis holds

This is a demo, so these are **validation signals**, measured locally or by hand with a few real accounts, not growth KPIs.

| Signal | Target |
|---|---|
| **Count precision**: share of Needs me items the user opens or acts on (rather than dismisses as noise) | ≥ 80% |
| **Missed direct asks**: direct review requests visible in github.com/pulls but absent from Needs me | 0 |
| **Auto-clean share** on a team-heavy account: threads cleared by rules without user action | ≥ 50% |
| **Time to zero** on Needs me (median session) | < 60 s |
| **Latency**: hotkey to interactive / keystroke to render | < 100 ms / < 50 ms |
| **Divergence**: synced states differing from github.com after one poll + dispatch | 0 |
| **API**: idle cost / cost at 500 unread with churn | ~0 / ≤ 12% |

---

## 15. Milestones

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0: Spikes** | S1–S5 (section 16) against a sandbox account; device-flow OAuth App registered | Each spike answered and written up; thesis adjusted if needed |
| **M1: Skeleton** | Status item, hotkey, panel, device-flow sign-in, conditional polling, SQLite cache, flat list | Opens in <100 ms; correct unread list; 304 idle |
| **M2: The classifier** | GraphQL enrichment of changed threads, actor/ownership classification, four splits, orphan search, Needs me count | Table-driven classifier tests; count matches hand-audited truth on 2 real accounts |
| **M3: Verbs** | Done/open/unsubscribe/mark read/snooze/later, persisted paced queue, undo window, bulk, Cmd+K, toasts, keymap | Kill/relaunch tests lose nothing; no false resurfacing |
| **M4: Rules and alerts** | R1–R4, Cleared log, Get me to zero, needs-me banners, quiet hours, onboarding summary | Auto-clean share and count precision measured |
| **M5: Polish** | Settings, hover actions, search qualifiers, accessibility pass, signed build | Demo-ready |

---

## 16. Risks, spikes, open questions

**Spikes (M0), to settle before building UI:**

| # | Question | Why it matters |
|---|---|---|
| S1 | Does GraphQL `IGNORED` suppress a later @mention? Does REST `DELETE …/subscription` let it through as documented? | Defines `u` vs "Ignore thread" |
| S2 | Exactly which new activity brings a Done thread back, in `all=false` and `all=true`? | Done ledger and "back:" notes |
| S3 | Does the direct-vs-team heuristic match github.com/pulls' split? | Core of Needs me |
| S4 | Cost and accuracy of the direct-review-request search (for example `user-review-requested:@me`) | Orphan detection |
| S5 | Does the `team_mention` reason persist after a later direct mention on the same thread? (A reason can stay at its earlier value.) | Split stability |

**Risks:**

| Risk | Mitigation |
|---|---|
| OAuth App access to notifications works in practice but GitHub documents classic PATs only | Keep PAT fallback; monitor changelog |
| GitHub ships state filters and bot muting in notifications | Caton's value moves to the desktop surface, keyboard, and rules; acceptable for a demo |
| Heuristics misclassify (bot lists, team vs direct) | Visible Cleared log, undo, editable lists, "why is this here?" in Cmd+K |
| Full `repo` scope feels heavy | Lite mode; clear copy; tokens never leave the Mac |
| Secondary rate limits during bulk clears | Paced queue; UI already optimistic |
| 3-month server retention | Local store holds history; Cleared log is local |
| Linear and Graphite pull review notifications into their own inboxes | Caton complements them by clearing GitHub's threads they can't touch |

---

## Appendix A: What changed from the Octodot-derived draft

**Kept:** conditional polling; optimistic persisted action queue keyed on thread ID + `updated_at`; AppKit panel hosting SwiftUI; Vim keymap with key-up firing for single-shot keys; stable repo ordering; toasts; hover actions; Inbox (read-but-not-done) semantics; issues and PRs as the primary focus.

**Changed:**

| # | Octodot draft | Caton |
|---|---|---|
| 1 | Paginate at 100 | Page at 50 (API cap), `since` deltas, periodic full reconcile |
| 2 | Unsubscribe = GraphQL `IGNORED` + local mute auto-lift | `u` = REST `DELETE …/subscription` + Done (lets mentions through); `IGNORED` is a separate, explicit "Ignore thread" |
| 3 | PAT at P0, device flow at P1 | Device flow at P0; `gh` import and PAT as fallbacks; fine-grained tokens explicitly unsupported |
| 4 | Enrich ~20 visible rows, batches of 40 | Enrich every changed thread, batches of 50; re-check open subjects |
| 5 | Inbox/Unread modes; "needs me" lane P1; rules P2; no banners | Four splits at P0; read is an attribute; rules R1–R4 at P0; needs-me banners at P0 |
| 6 | Undo P1 (Octodot removed it) | Undo P0 as a grace window before dispatch |
| 7 | Bulk = one request per thread, unpaced | Paced serial dispatch, ≥1 s apart in bulk |
| 8 | Silently drop non-issue/PR types | Route them to Feed as clearable bundles, so the two inboxes don't diverge |
| 9 | Maintainer listed first | Team reviewer is primary; maintainer secondary |
| 10 | Competitive frame predates 2026 | Positioned against GitHub /pulls, gh-dash notifications, Linear Diffs |

---

## Appendix B: GitHub API reference

| Purpose | Call |
|---|---|
| Identity / scopes | `GET /user` (read `X-OAuth-Scopes`) |
| Inbox feed | `GET /notifications?all=false&per_page=50&page=N[&since=…]` with `If-Modified-Since` |
| Read-not-done window | `GET /notifications?all=true&since=<window>&per_page=50` |
| Mark read | `PATCH /notifications/threads/{id}` |
| Done | `DELETE /notifications/threads/{id}` |
| Unsubscribe (mentions still notify) | `DELETE /notifications/threads/{id}/subscription`, then Done |
| Ignore (never notify) | GraphQL `updateSubscription(subscribableId, state: IGNORED)` or REST `PUT …/subscription {"ignored": true}`, then Done |
| Enrichment | GraphQL aliased `repository(owner,name){ pullRequest(number){…} / issue(number){…} }`, 50 per query |
| Orphan review requests | GraphQL `search(type: ISSUE, query: "is:pr is:open user-review-requested:@me archived:false")` (S4) |
| Limits and hints | `X-Poll-Interval`, `Last-Modified`, `Retry-After`, `X-RateLimit-Remaining/Reset` |
| Not available | Saved, snooze, custom filters, sort order, GraphQL notifications, inbox webhooks, mark-unread, bulk done |

**Reason values (15):** `approval_requested` · `assign` · `author` · `ci_activity` · `comment` · `invitation` · `manual` · `member_feature_requested` · `mention` · `review_requested` (you *or* your team) · `security_advisory_credit` · `security_alert` · `state_change` · `subscribed` · `team_mention`.

---

## Appendix C: Glossary

| Term | Meaning |
|---|---|
| **Thread** | A GitHub notification thread for one subject (issue, PR, release, …). |
| **Activity key** | Thread ID + `updated_at`. Identifies what the user actually saw and dismissed. |
| **Split** | One of four mutually exclusive inbox partitions: Needs me, Team, Following, Feed. |
| **Direct vs team** | Whether a review request names you personally or reaches you through a team. |
| **Actor type** | Human, bot, AI reviewer, or agent, inferred from the author. |
| **Done** | Removed from GitHub's inbox; returns on new activity. |
| **Unsubscribe** | Stop notifications on the thread except when you're mentioned or asked for review; also Done. |
| **Ignore** | Never notify on this thread again; also Done. |
| **Snooze** | Local: hidden until a time or new needs-me activity, whichever comes first. |
| **Later** | Local saved list (GitHub's Saved has no API). |
| **Cleared log** | Local record of rule and bulk actions, with undo during the grace window. |
| **Grace window** | Delay before a mutation is sent, during which undo is exact. |

---

## 17. Build status (2026-10-03)

Built on Baton 0.6.0 in `Sources/`; `swift test` runs 106 tests (CatonCore and the app model).

| Area | Status |
|---|---|
| Menu bar count (or icon only), tooltip and VoiceOver with every split's count, right-click Refresh / Settings / Check for Updates / Quit | Built |
| Global shortcut with fallback; second shortcut into Needs me (MB-07) | Built |
| Panel drawn as a macOS 26 menu (glass, rounded window), resizable; detachable into an ordinary window (PA-08) | Built |
| Sign-in: device flow through Caton's OAuth App (`Ov23liz9s5AlvZVZWZ2k`), Full or Lite scopes, GitHub CLI token, classic PAT | Built; the OAuth App accepts device-code requests, a full sign-in not yet run |
| Several accounts, one shown at a time; GitHub Enterprise Server and GHE.com hosts (AU-07) | Built; Enterprise endpoints tested against stubs only, no Enterprise account used |
| REST feed: conditional polling at 50 per page, read-not-done window (configurable), rate governor shared with GraphQL | Built |
| Status strip by priority: error, rate-limit cooldown, warning, update (PA-05) | Built |
| Subject state through Baton, image hydration on relaunch | Built; verified on a 9-thread account |
| Four splits, direct-vs-team via `reviewRequests` and `viewerLatestReviewRequest`, actor kinds (Apps, machine users named like bots, editable bot / AI reviewer / agent lists) | Built; heuristic not yet compared with github.com/pulls (S3) |
| "Why is this here?" from the classifier's own reasoning | Built |
| Feed bundles per bot and per busy repository (PA-03) | Built |
| Rules R1–R4, Cleared log with restore and links, rule exemptions; GitHub sync opt-in from the welcome summary or Settings | Built |
| Verbs: open, done, unsubscribe, ignore, mark read, snooze (with follow-up mode), later, mute repo, bulk, undo, peek, copy link | Built |
| Specific resurfacing notes: re-requested, checks failed, changes requested, approved, new comment by @x, asked again, snooze ended, no reply yet | Built |
| Get me to zero with a count preview per option (AC-09) | Built |
| Paced persisted queue, grace window, drain on quit | Built |
| Search with qualifiers, unread only, grouping with stable repository order; saved searches as splits (SE-04) | Built |
| Cmd+K command menu, `?` keymap, footer hints, hover actions, hover checkbox, three-key tip (OB-03), practice inbox (OB-05) | Built |
| Orphan review-request search (8.3) | Built; the account used had no review requests, so only its cost (1 point) is verified |
| Banners, quiet hours, per-poll cap, morning digest (AL-04) | Built; needs the bundled app; not yet seen on screen |
| Settings: General, Rules, Alerts, Account, Shortcuts, About (with local-only weekly stats) | Built |
| Accessibility: row labels with state, author and age, row actions, Reduce Motion | Built; not yet audited with VoiceOver end to end |
| Updates | Checked against GitHub Releases; the status strip, the menu and About show `brew upgrade --cask caton`. The cask itself and signed, notarized releases (UP-01, needs a Developer ID) are not set up yet |
| Multiple accounts at once (polling every account, a merged count) | Not built: one account shows at a time |
| Spikes S1, S2 | Not run: they mutate notifications and need a sandbox account |
| Spike S3 | Open: needs an account with direct and team review requests |
| Spike S4 | Answered: `user-review-requested:@me` costs 1 point |
| Spike S5 | Answered by the build: a thread's reason stayed `mention` years after the mention, while the latest activity was a bot closing the issue. Facts now include the latest commenter, and an old mention on a subject a bot closed is no longer Needs me |

Improvements Baton needs, found while building, are in Baton's notes.
