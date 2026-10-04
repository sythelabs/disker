# Disker backend

## Scope

Native macOS 26 backend for a WinDirStat-style disk tree. Prioritize startup latency, metadata traversal throughput, durable incremental caching, raw filename fidelity, and complete drilldown. Leave the UI unchanged. Read filesystem metadata only; content checksums would read the entire disk and are not appropriate for size invalidation.

## Architecture

- `DiskerCore`: scanner, SQLite index, FSEvents journal, and separate Git inspection.
- `CDiskerScan`: native bulk directory metadata connector using `getattrlistbulk`.
- `disker-index`: command-line scan/query/benchmark harness using the same backend.
- GRDB over SQLite WAL, full synchronous commits, indexed parent queries, flat nodes, raw byte paths. Cache queries do not traverse the filesystem or load the whole tree. Scanning runs on GRDB's writer queue; readers, including newly opened processes, retain access to the previous committed snapshot.
- Streaming, synchronous batch callbacks provide backpressure. Rows and progress delivered before completion are provisional; a completed event identifies the durable transaction.

## Scan contract

Iterative traversal with no application depth limit. Never follow symlinks. Preserve permissions, ownership, device/inode identity, link count, flags, timestamps, logical size, and allocated size. Report inaccessible, vanished, excluded, and alias paths explicitly. Root scans cross devices and deduplicate actual directory identities to avoid APFS firmlink duplicate traversal. Persist aliases so callers can drill into either visible path without counting the same directory twice. Home scans remain on one device. The dedicated application cache directory is explicitly excluded through logical, symlink-resolved, and physical paths to avoid self-generated changes.

Memory scales with pending directories and visited directory identities, rather than all files. Scanner batches and the native metadata buffer have fixed sizes. The scanner can descend beyond `PATH_MAX` through directory descriptors; selected roots used by the journal remain subject to the macOS physical-path limit. Cached descendant queries retain arbitrary raw path bytes.

Logical totals count each visible file path. Allocated totals also count each visible path; hard links expose their identity so callers can distinguish aliases. Neither total is a reclaimable-space estimate: APFS clones, compression, snapshots, and shared extents require separate analysis. Symlink sizes describe the link, not its target. Directory logical sizes do not inflate file totals.

## Durability and incremental refresh

Open and query the previous committed snapshot immediately. Start the FSEvents stream before reconciliation. Persist its journal UUID and cursor with node changes in the same transaction. Reconcile changed directories and recursively scan new or invalidated subtrees. After scanning, drain events that raced with the scan. Never advance the persisted cursor past unapplied changes. Missing journals, dropped events, root changes, or uncertain volume coverage force metadata reconciliation.

The first implementation conservatively fully reconciles `/` because its tree spans multiple device journals. Single-device roots use persisted per-device events. Root results can be incomplete because of macOS privacy and filesystem permissions; expose errors and coverage, not an invented complete tree. If root itself is inaccessible, selecting home is supported explicitly. Retargeting retains independent cached roots.

Transactions keep the previous committed snapshot valid if cancelled or interrupted. Incomplete scans retain older unreachable subtrees and expose issues; these totals may contain stale metadata. Unchanged permission gaps reuse the cache without rescanning the accessible tree. A filesystem event or explicit full refresh retries them. Transient scan errors retry affected scopes, and successful reconciliation removes resolved issues. Root identity changes, including changed device identity after a remount, can force full reconciliation.

FSEvents delivery is asynchronous: a refresh immediately after a write may still return the previous state. Subsequent refreshes converge when events arrive. There is no atomic live-filesystem snapshot: concurrent writes can continue after any reconciliation boundary.

## Git enrichment

Detect `.git` markers during traversal without subprocesses. Perform Git commands on a separate utility task when enrichment is requested. Persist repository/worktree details with a subtree revision and Git input fingerprint. Changes to either invalidate enrichment; a filesystem refresh must observe working-tree edits before the cached dirty status changes. Recheck revision and fingerprint before storing asynchronous results. Distinguish latest HEAD commit time, latest file modification time, and uncommitted changes. A `.git` file alone does not prove a linked worktree. Git inspection disables optional locks and filesystem monitor hooks, has a timeout, and rejects nonregular metadata files before reading. No cleanup/delete operations in this backend.

## Progress and performance

Stream batches and progress counters: entries and bytes observed, elapsed time, previous node count, and completion. Final summaries additionally report directories, bulk calls, and metadata calls. The first scan has no reliable total, so progress is indeterminate. A previous node count is an estimate, not a trustworthy percentage. Benchmarks report a full scan with an empty application cache, cached reopening/query, a separate-process summary query, unchanged refresh, changed refresh, nodes/second, cache size, and peak process RSS. Resize measurements separate the successful reconciliation call from total convergence time, including event delivery and retries. Freshly created fixture files have warm OS filesystem caches; this is not a cold-disk measurement.

## Validation

Real temporary filesystem and Git fixtures; SQLite restart tests; incremental mutations after shutdown; cancellation rollback; streamed batches; symlink cycles; sparse files; hard links; deep trees; filename byte preservation; journal loss policies. Performance uses deterministic fixtures in release builds. Report measurements and their machine/fixture context rather than assert universal throughput.

## Sources

- Apple XNU bulk traversal: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_attrlist.c
- Apple FSEvents guide: https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html
- SQLite WAL: https://www.sqlite.org/wal.html
- Git repository layout: https://git-scm.com/docs/gitrepository-layout
