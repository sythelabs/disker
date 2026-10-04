# Disk index implementation plan

**Goal:** Build and measure a durable, streamed native disk tree backend without changing the UI.

**Architecture:** Native bulk traversal feeds a flat SQLite tree. Persisted FSEvents select reconciliation scopes. Git enrichment runs separately and is cached against scan and Git revisions.

**Tech stack:** Swift 6.2, macOS 26, Darwin C APIs, GRDB/SQLite, CoreServices FSEvents, Swift Testing.

**Spec:** `docs/backend-design.md`.

## Constraints

- macOS 26 only. ASCII source text and UI copy.
- Read filesystem and Git state; write only cache and temporary test/benchmark fixtures.
- Explicit error and incompleteness reporting. No file content reads on the scan path.
- Raw path bytes, iterative traversal, bounded batches, indexed child queries.

## Tasks

- [x] Native scanner: `FileMetadata.swift`, `DirectoryScanner.swift`, `CDiskerScan`. Write filesystem fixtures first, observe failures, implement bulk metadata and iterative streaming, verify symlinks/links/deep/invalid paths.
- [x] Journal: `FileEventJournal.swift`. Test persisted replay, lost-history policy, root changes, and race draining before using event checkpoints.
- [x] Durable tree: `DiskIndex.swift`, `IndexTypes.swift`. Test reopen without traversal, mutations, cancellation rollback, retargeting, and indexed child totals first. Implement transactional scopes and aggregates using GRDB.
- [x] Git: `GitInspector.swift` and SQLite enrichment cache. Test regular repo, linked worktree, separate git directory, detached/unborn HEAD, dirty state, and cache invalidation. Keep commands outside traversal.
- [x] Harness: `DiskerIndexCLI`, just recipes, release fixture benchmark. Verify streamed progress and actual work counters; record reproducible performance evidence.
- [x] Integration: full test suite, build, fresh review, documentation of measured results and limits.

## Review focus

- Dropped events or offline volumes must never silently establish freshness.
- Partial directory enumeration must not delete still-existing cached children.
- Symlinks, firmlinks, hard links, and sparse files must keep distinct semantics.
- Changes during scans and asynchronous Git work must not advance a stale cursor/revision.
- Cache writes inside the indexed root must not force continuous rescanning.

## Verification evidence

- `just test`: 61 tests pass.
- `just build`: app bundle builds and signs; strict signature verification and plist validation pass.
- Native C passes `-Wall -Wextra -Werror`; CLI scan, summary, and children preserve spaced arguments.
- Final release reports: [20,000 files](performance-2026-10-04-20000.json), [100,000 files](performance-2026-10-04-100000.json). Both pass verification, with zero unchanged traversal and zero content reads.
- Platform limits and asynchronous event semantics remain explicit in [the design](backend-design.md).
