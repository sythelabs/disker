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

<!-- sythelabs:layout-spacing-ownership:v1 -->
## Layout and component spacing ownership

This is a standing rule for UI work across Sythe Labs repositories.

- **Layouts own spacing between components.** Page and section layouts own outer padding, responsive gutters, alignment, and the gaps between sibling sections. Each inset has one owner; do not add it again in headers, toolbars, summaries, or content wrappers. Layout-owned padding does not authorize appearance or padding overrides on shared content primitives.
- **Components own their content.** Content components own their markup, state, behavior, and internal spacing. They do not add compensating outer margins, padding, spacer elements, or offsets to position neighboring sections or align themselves with a page gutter.
- **Use native layout primitives.** In Tailwind, prefer one statically padded stack (`p-*`) with `gap-*` for flex/grid children; use `space-y-*` for a normal block stack when appropriate. Use responsive utilities for responsive gutters. Do not calculate layout spacing in JavaScript or branch padding/margins on which slots are null, empty, loading, or populated.
- **Optional content only changes rendering.** Omit absent sections and let the layout's gap handle the remaining siblings. Do not require empty placeholder slots or components to manufacture spacing.
- **Fix shared layout defects at their owner.** For apps using `@sythelabs/ui`, reusable layout primitives belong in that package; consume its published release rather than copying its implementation or adding per-page overrides. Other stacks use their own shared native layout primitives. Preserve bounded scrolling and flex/grid sizing while changing spacing.

| Rule | Required verification |
| --- | --- |
| One layout owns page/section gutters and sibling gaps | Rendered layout regression checks with optional sections both present and absent |
| Components do not compensate for page-level spacing | Review component boundaries and callers; remove duplicate outer insets rather than hiding them with offsets |
| Responsive spacing stays consistent | Browser geometry checks at narrow and wide widths; check heading/action alignment, clipping, overflow, and scrolling |

Keep fixes scoped to spacing ownership. Do not change typography, business behavior, credentials, or deployment configuration as part of a spacing correction.
