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

## Project

- `Package.swift` defines the Swift package.
- `Sources/Disker/DiskerApp.swift` is the app entry point.
- `Sources/Disker/ContentView.swift` defines the starter window.
- `Info.plist` defines the macOS app bundle metadata.
- `just build` builds and ad-hoc signs `.build/Disker.app` for local development.
- `just run` builds and launches the app.
- `just test` runs the backend tests with the full Xcode toolchain.
- `just index` runs the backend command-line harness; quote paths containing spaces.
- `just benchmark 100000` measures a deterministic temporary fixture in a release build.
