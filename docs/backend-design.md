# Disker backend

## Scope

Native macOS 26 backend for a WinDirStat-style disk tree. Prioritize startup latency, metadata traversal throughput, durable incremental caching, raw filename fidelity, and complete drilldown. Read filesystem metadata only; content checksums would read the entire disk and are not appropriate for size invalidation.

## Architecture

- `DiskerCore`: scanner, SQLite index, FSEvents journal, and separate Git inspection.
- `CDiskerScan`: native bulk directory metadata connector using `getattrlistbulk`.
- `disker-index`: command-line scan/query/benchmark harness using the same backend.
- GRDB over SQLite WAL, full synchronous commits, indexed parent queries, flat nodes, raw byte paths. Cache queries do not traverse the filesystem or load the whole tree. Short transactions run on GRDB's writer queue; readers, including newly opened processes, see the latest durable observations while scanning continues.
- Streaming, synchronous batch callbacks provide backpressure. Every streamed batch commits before delivery. Totals remain provisional until directory coverage is complete; cancellation retains the observations.

## Scan contract

Iterative traversal with no application depth limit. Never follow symlinks. Preserve permissions, ownership, device/inode identity, link count, flags, timestamps, logical size, and allocated size. Report inaccessible, vanished, excluded, and alias paths explicitly. Root scans cross devices and deduplicate actual directory identities to avoid APFS firmlink duplicate traversal. Persist aliases so callers can drill into either visible path without counting the same directory twice. All selected folders use the same cross-device traversal policy, so coverage has one meaning. The dedicated application cache directory is explicitly excluded through logical, symlink-resolved, and physical paths to avoid self-generated changes.

Memory scales with pending directories and visited directory identities, rather than all files. Scanner batches and the native metadata buffer have fixed sizes. The scanner can descend beyond `PATH_MAX` through directory descriptors; selected roots used by the journal remain subject to the macOS physical-path limit. Cached descendant queries retain arbitrary raw path bytes.

Logical totals count each visible file path. Allocated totals also count each visible path; hard links expose their identity so callers can distinguish aliases. Neither total is a reclaimable-space estimate: APFS clones, compression, snapshots, and shared extents require separate analysis. Symlink sizes describe the link, not its target. Directory logical sizes do not inflate file totals.

## Durability and incremental refresh

Files are identified by their raw absolute path, independently of the folder selected in the UI. `nodes.path`, `directories.path`, `aliases.path`, and `git_cache.path` are global keys. Nodes retain their real parent; only `/` has no parent. Ancestor rows are materialized from metadata so observing a home folder also updates its known totals under `Users` and `/`. Selecting another folder changes the query boundary, not ownership of the files.

Start a host FSEvents stream for `/` before reconciliation. A single checkpoint advances atomically with global directory invalidations. Changes outside the selected view remain pending for their next refresh. Logical and physical path projections translate symlinks and APFS firmlinks back to observed paths. Per-host event IDs are fenced by the boot session, mounted device set, and volume journal UUIDs. A reboot, topology change, dropped history, or other uncertain coverage invalidates freshness while retaining all observed rows.

### Shared observations and durable coverage

- Problem: root-keyed committed and staging databases duplicated the same files and prevented parent, child, and interrupted scans from sharing knowledge. The `/` exception also discarded staging when replay coverage was unavailable.
- Usage: the existing `DiskIndex` API remains a view over one cache:

```swift
_ = try await index.refresh(root: home, mode: .automatic, receiveEvent: receiveEvent, isCancelled: isCancelled)
let drive = try await index.cachedSummary(root: "/")
let homeChildren = try await index.children(root: "/", directory: Data(home.utf8), offset: 0, limit: 500)
let progress = try await index.cachedProgress(root: home)
```

- Shape: one SQLite WAL database stores observations and a global directory frontier. `directories.done` records freshness; `directories.observed` records completed observation work and survives invalidation. Each 512-entry batch upserts paths and recomputes affected ancestors in a short transaction. Directory reports and completed coverage commit before scanning the next directory. An unfinished listing restarts, updating the same records. Its missing children are pruned only after a successful complete listing.
- Reads: summaries, bounded child pages, restored progress, and the native model all use this database. The model has no second filesystem preview or aggregate tree. Revision checks reject pagination across mutations, and selected rows retain their ordering while updates arrive.
- Recovery: failed directory reports retry locally, including permission changes without filesystem events. Known inaccessible subtrees remain visible with explicit issues. An incomplete summary is durable knowledge, not a complete filesystem snapshot. Querying or switching views preserves known counts, sizes, and observation progress.
- Migration: schema 1 is flattened transactionally into schema 2. Overlapping paths collapse to one row. Valid interrupted sidecar observations are imported even without a checkpoint; staging with an obsolete base revision is ignored. Existing ancestor metadata connects previously isolated roots. The old sidecar is retained as an inactive recovery artifact; old tables are removed inside the migration transaction. Journal freshness is conservatively revalidated once under the new global checkpoint. Git enrichment is rebuilt on demand.
- Synthesis decision: choose the direct global observation graph with durable directory coverage. It hides persistence, totals, cancellation, aliases, and event reconciliation behind the existing query/refresh API. Global immutable versions and directory manifests would preserve whole-tree publication but require separate committed/observed query modes and garbage collection. Root-keyed staging would retain the ownership defect. Both were rejected.
- Tradeoffs accepted: readers can see durable partial updates instead of an atomic whole-root rollback. This makes observed files immediately reusable and removes sidecar promotion and duplicate UI aggregation. Synchronous batch commits cost throughput; only changed ancestor totals are rebuilt. Host journal fencing may require freshness work after reboot or mount changes, but it never deletes observations merely because a view changes.
- Risks: filesystem mutation remains concurrent with scanning; coverage and permission issues must stay explicit. Symlinks themselves remain files, and traversal does not follow them. A selected path beneath a symlink can retain its raw identity without inventing a directory node for the symlink ancestor. Progress estimates known directory work, reserves the last five percent for completion, and may change as new branches become known.
- Validation: parent-first and child-first selection, drive ancestor totals, partial cancellation/reopen, repeated interruption, cross-view navigation, migration rollback, changes while closed, permission recovery, concurrent readers/writers, raw filenames, aliases, and release benchmarks.

FSEvents delivery is asynchronous: a refresh immediately after a write may still return the previous state. Subsequent refreshes converge when events arrive. There is no atomic live-filesystem snapshot: concurrent writes can continue after any reconciliation boundary.

## Git enrichment

Detect `.git` markers during traversal without subprocesses. Perform Git commands on a separate utility task when enrichment is requested. Persist repository/worktree details with a subtree revision and Git input fingerprint. Changes to either invalidate enrichment; a filesystem refresh must observe working-tree edits before the cached dirty status changes. Recheck revision and fingerprint before storing asynchronous results. Distinguish latest HEAD commit time, latest file modification time, and uncommitted changes. A `.git` file alone does not prove a linked worktree. Git inspection disables optional locks and filesystem monitor hooks, has a timeout, and rejects nonregular metadata files before reading. No cleanup/delete operations in this backend.

## Progress and performance

Stream batches and progress counters: entries and bytes observed, elapsed time, previous node count, and weighted directory completion. Restore retained entries and completion on resume. Final summaries report newly performed filesystem work, including directories, bulk calls, and metadata calls; restored rows do not inflate these metrics. A previous node count is an estimate, not a trustworthy percentage. Benchmarks report a full scan with an empty application cache, cached reopening/query, a separate-process summary query, unchanged refresh, changed refresh, nodes/second, cache size, and peak process RSS. Resize measurements separate the successful reconciliation call from total convergence time, including event delivery and retries. Freshly created fixture files have warm OS filesystem caches; this is not a cold-disk measurement.

## Validation

Real temporary filesystem and Git fixtures; SQLite restart tests; incremental mutations after shutdown; durable cancellation; streamed batches; symlink cycles; sparse files; hard links; deep trees; filename byte preservation; journal loss policies. Performance uses deterministic fixtures in release builds. Report measurements and their machine/fixture context rather than assert universal throughput.

Shared-cache validation on 2026-10-07: all 152 tests passed. Native navigation retained 601 observed nodes in a child and 603 in its parent across repeated back/forward switches. The development app built and signed successfully.

Release benchmark on Apple M5 with 32 GiB memory, 100,000 newly created files and 100,783 nodes, warm OS filesystem caches:

| Measurement | Result |
| --- | --- |
| Full scan | 3.820 s, 26,384 nodes/s |
| Reopen and query | 6.58 ms |
| Fresh-process cached query | 11.11 ms |
| Unchanged refresh | 21.86 ms, zero directory traversals |
| Single-file resize reconciliation | 26.48 ms, one directory traversed |
| Resize convergence including event delivery | 57.02 ms, two refresh attempts |
| Peak resident memory | 177.7 MiB |

Benchmark verification passed; scans read zero content bytes.

## Sources

- Apple XNU bulk traversal: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_attrlist.c
- Apple FSEvents guide: https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html
- SQLite WAL: https://www.sqlite.org/wal.html
- Git repository layout: https://git-scm.com/docs/gitrepository-layout
