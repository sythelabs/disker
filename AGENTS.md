# Disker

## Product direction

- Build a full, canonical native macOS app using SwiftUI.
- Target macOS 26 and later exclusively. Use macOS 26 APIs directly, including native Liquid Glass, without compatibility paths for older macOS versions.
- Use Apple's standard styling and platform conventions out of the box.
- Prefer built-in SwiftUI controls, system fonts, semantic colors, SF Symbols, standard window behavior, and native menus.
- Honor macOS accessibility, keyboard navigation, and light and dark appearance.
- Keep the initial app simple. Defer custom styling, elaborate visuals, and bespoke interactions until explicitly requested.
- Do not introduce web-based UI frameworks or cross-platform wrappers.

## Backend

- Performance is a primary requirement: measure scan throughput, cached query latency, refresh work, and memory on reproducible fixtures.
- Stream filesystem batches and progress independently of Git enrichment.
- Persist filesystem and Git caches with explicit invalidation and durable transactions.
- Prefer established, well-tested, widely used libraries for solved problems. Use GRDB for SQLite access; write custom code only when platform requirements or measured performance justify it.
- Treat permission gaps and stale metadata as explicit states. Preserve raw path identity and avoid reading file contents during size scans.

## File tree

- Start in the user's home folder and allow retargeting through the native folder picker.
- Show files and expandable folders with aligned size columns and proportional bars. Use native table scrolling and resizable columns.
- Query expanded branches in bounded pages and publish scan updates in batches. Keep indexing and preview aggregation off the main actor.
- Preserve raw byte paths as row identities and distinguish provisional scan totals from committed snapshots.

## Project

- `Package.swift` defines the Swift package.
- `Sources/Disker/DiskerApp.swift` is the app entry point.
- `Sources/Disker/ContentView.swift` defines the native file tree window.
- `Sources/Disker/DiskTreeModel.swift` connects cached child queries and streamed scan progress to visible branches.
- `Info.plist` defines the macOS app bundle metadata.
- `just build` builds and ad-hoc signs `.build/Disker.app` for local development.
- `just run` builds and launches the app.
- `just test` runs the backend and file-tree model tests with the full Xcode toolchain.
- `just index` runs the backend command-line harness; quote paths containing spaces.
- `just benchmark 100000` measures a deterministic temporary fixture in a release build.

## Prefer Cloudflare's platform over hand-written implementations

This service runs on Cloudflare. Before writing code for something the platform already does, use the
platform. Never hand-roll a scheduler, queue, retry loop, lock, blob store or configuration loader.

- periodic work -> **Cron Triggers** (`scheduled()`), never a daemon, timer loop or "scheduler" service
- async work, fan-out, retries, backoff, dead-letter -> **Cloudflare Queues**, never Redis/bullmq and never
  hand-written retry code
- state and locking -> the rows you already have (Postgres `SELECT ... FOR UPDATE SKIP LOCKED`), not a separate
  lock service
- long, multi-step or resumable work -> **Workflows**; durable coordination -> **Durable Objects**
- objects and large payloads -> **R2**; small hot reads -> **KV** or the Cache API
- configuration and secrets -> Worker vars and secrets, not a bespoke loader
- tests -> the Workers test pool, not hand-rolled platform mocks

Prefer an official Cloudflare binding or client library over a hand-written client, and name the library in the PR
body. A supported adapter beats custom glue; when an adapter is third-party rather than first-party (for example
OpenNext for Next.js on Workers), say so plainly instead of implying it is native.

If, and only if, there is genuinely no native option, the glue you write must be declared in the PR body as
`custom - why there was no native option`. No silent custom layers.

Design to the real limits: a Queue consumer and a Cron Trigger each get 15 minutes of wall time, CPU is capped
(configurable up to 5 minutes), and a single request may hold only 6 simultaneous outgoing connections with 128 MB
of memory. Fan work out across messages and let the platform supply the concurrency.
