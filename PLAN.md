# Plan: a native, recursive, callback-based file watcher for Julia

Working name ideas: `NativeFileWatching.jl` / `RecursiveFileWatching.jl` (BetterFileWatching v2?).

## Goal

A drop-in successor to [BetterFileWatching.jl](https://github.com/JuliaPluto/BetterFileWatching.jl) that is:

- **recursive** — one call watches a whole tree, including directories created later
- **callback-based** — `watch_folder(f, dir)` calls `f(event)` per event
- **pure Julia** — no Deno_jll (~30 MB), no subprocess, no IPC flakiness, no binary deps at all
- **stoppable via CancellationTokens.jl** — instead of `schedule(task, InterruptException(); error=true)`

## Feasibility: HIGH ✅ (all risky parts validated by experiments, see [LEARNINGS.md](LEARNINGS.md))

The entire package is an estimated **500–800 lines of pure Julia**. The two hard problems are already solved
in prototype form in [`experiments/`](experiments/):

| Platform | Backend | Status |
|---|---|---|
| macOS | libuv `uv_fs_event` + `UV_FS_EVENT_RECURSIVE` (FSEvents underneath) | ✅ validated locally |
| Linux | raw `inotify` via ccall + `FileWatching.FDWatcher` (uv_poll) | ✅ validated in Docker, incl. new-dir race fix + 5k-dir stress |
| Windows | same code as macOS backend (libuv → RDCW with subtree) | ✅ validated in CI (22/22 tests, Julia 1.10 + 1.12) |
| FreeBSD | out of scope initially (libuv kqueue backend is non-recursive) | fallback: error or per-dir monitors later |

## Public API

```julia
# Blocking; returns when token is cancelled. Throws on watcher errors.
watch_folder(f::Function, dir::AbstractString=".", token::CancellationToken)

# Compat mode (BetterFileWatching-style): blocks forever, stop by interrupting the task.
watch_folder(f::Function, dir::AbstractString=".")

# Same but for a single file (watch parent dir, filter to the file).
watch_file(f::Function, path::AbstractString, [token])
```

Events (BetterFileWatching-compatible shape — `.paths::Vector{String}` of absolute paths):

```julia
abstract type FileEvent end
struct Created  <: FileEvent; paths::Vector{String}; end
struct Modified <: FileEvent; paths::Vector{String}; end
struct Removed  <: FileEvent; paths::Vector{String}; end
struct Renamed  <: FileEvent; paths::Vector{String}; end   # when the OS gives us a pair
```

Options (keywords on `watch_folder`):
- `ignore::Function = p -> false` — predicate on relative path; skip watching matching dirs (think
  `.git`, `node_modules`). Cheap on Linux (don't add the watch), filter-only on macOS/Windows.
- `latency::Float64` — coalescing window (bun uses ~100µs extra wait; FSEvents has its own latency parameter,
  libuv hardcodes it — we just document what the OS gives us).

Documented semantics (learned from bun + experiments):
- **at-least-once**: duplicates possible (esp. around new-directory scans on Linux); consumers must be idempotent.
- **event kinds are best-effort**, precise on Linux/Windows, coarser on macOS (libuv collapses FSEvents flags to
  rename/change; we disambiguate with `ispath` and optionally an mtime cache).
- editors atomic-save (write tmp + rename), so a "save" may surface as Created/Renamed, not Modified.
- overflow (huge burst) may drop events; we surface a `lost_events` marker or resync rather than erroring
  (bun's Windows re-arm lesson).

## Package structure

```
src/
  NativeFileWatching.jl   # API, event types, dispatch to backend
  common.jl               # event coalescing/merge, ignore filtering, path utils
  backend_uv.jl           # macOS + Windows: RecursiveFolderMonitor (uv_fs_event, flags=4)
  backend_inotify.jl      # Linux: inotify ccall + FDWatcher + dynamic dir registry
test/
  runtests.jl             # shared black-box scenario suite, runs on all platforms in CI
```

Backend contract (internal): `start(root; ignore) -> Channel{RawEvent}`, `close(backend)`. The public
`watch_folder` maps raw events → `FileEvent`s and pumps the callback in the calling task, wrapped in
`take!(channel, token)` for cancellation.

### Design choices carried over from bun

- coalesce bursts, then merge per-path before dispatch (sort + OR the op flags)
- treat `MOVED_TO`/rename-target as a content change (atomic saves)
- bounds-check/ignore events for already-removed watches; batch evictions
- overflow → resynchronize (rescan) instead of dying

### Design choices departing from bun

- no dedicated OS thread: libuv delivers uv_fs_event callbacks on Julia's event loop; the inotify fd waits via
  `FDWatcher` in a normal task
- whole-tree watching (FSEvents on macOS) instead of import-graph + fd-per-file kqueue
- Julia `Channel` as the event queue; user callback runs in the watching task, not under a lock

## Risks & mitigations

1. **Base internals** (`associate_julia_struct`, `iolock_begin`, …) for the uv backend are not public API.
   Small surface (~8 symbols), unchanged for many Julia versions, used identically by the stdlib itself.
   Mitigate: CI on 1.10 LTS through nightly; the Linux backend doesn't need them at all.
   Long-shot alternative: upstream a `flags`/`recursive` kwarg to `FileWatching.FolderMonitor` (PR to julia) and
   use internals only on old versions. Worth filing regardless — the fix is literally plumbing one integer.
2. **Windows untested locally.** First milestone after skeleton: GitHub Actions windows runner executing the
   scenario suite. libuv's RDCW path is extremely well-trodden (node), so risk is in our mapping code, not the OS.
3. **macOS event-kind coarseness** (append seen as rename). Mitigate with `ispath` + optional mtime cache;
   document. BetterFileWatching users already live with loose kinds.
4. **inotify limits** (`max_user_watches`, ENOSPC): per-dir watches keep counts low (5k dirs ≈ 5k watches,
   128k default limit); surface a clear error message with the sysctl to bump.
5. **Symlink cycles / mount points** on the Linux walkdir: don't follow symlinks (walkdir default), document.
6. **Pluto integration** (the real consumer): add an integration test mirroring how Pluto uses
   BetterFileWatching before registering.

## Milestones

1. ✅ **Skeleton package** (done 2026-07-02) — API + event types + uv backend, scenario test suite, CI matrix
   all green (macOS/Linux/Windows × Julia 1.10/1.12 + nightly): https://github.com/fonsp/BetterFileWatchingNext.jl
2. ✅ **Linux backend** (done 2026-07-02) — inotify + FDWatcher with ignore-predicate, rename pairing +
   dir-rename bookkeeping, overflow resync, watch eviction.
3. ✅ **Semantics polish** (done 2026-07-03) — batch layer in `common.jl`: `latency` coalescing window
   (default 10 ms, bun's second-wait trick), per-path duplicate suppression that still lets
   create→remove→create through, uv-backend rename pairing via `RenameHint` (reliable on Windows,
   best-effort on macOS). `watch_file` + Linux rename pairing were already in milestone 1+2.
4. **Docs + register** — README with BetterFileWatching migration section (the `@async`+`InterruptException`
   pattern still works; CancellationTokens is the new recommended way).
5. **(stretch)** upstream `recursive=true` to FileWatching stdlib; FreeBSD best-effort backend.

## Experiment inventory

| File | What it proves | Where it ran |
|---|---|---|
| `experiments/RecursiveFolderMonitor.jl` | FolderMonitor clone with flags exposed | — |
| `experiments/01_recursive_uv.jl` | flags=4 → recursive on macOS; silently ignored on Linux | macOS + Docker |
| `experiments/02_linux_inotify.jl` | inotify+FDWatcher recursion, new-dir race + fix | Docker julia:1.12 |
| `experiments/03_api_prototype.jl` | target API incl. CancellationTokens stop | macOS |
| `experiments/04_linux_stress.jl` | 5.1k dirs: 160 ms setup, ~2 ms latency | Docker julia:1.12 |
