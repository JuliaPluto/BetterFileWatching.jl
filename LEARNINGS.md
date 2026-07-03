# What we learned from bun's file watcher

Reference code: [`bun-watcher-reference/src/watcher/`](bun-watcher-reference/src/watcher/) (gitignored sparse clone of
[oven-sh/bun `src/watcher`](https://github.com/oven-sh/bun/tree/main/src/watcher), cloned 2026-07-02; bun recently
ported this code from Zig to Rust).

## Architecture

One shared driver ([`Watcher.rs`](bun-watcher-reference/src/watcher/Watcher.rs)) plus three platform backends,
selected at compile time. A dedicated watcher thread runs a blocking `watch_loop_cycle()` in a loop; a mutex +
atomic `running` flag coordinate with the main thread. The user callback (`on_file_update`) is invoked **on the
watcher thread while holding the mutex**.

| Platform | Backend | Recursive? | Identity |
|---|---|---|---|
| Linux/Android | `inotify` (`INotifyWatcher.rs`) | ❌ one watch **per directory and per file** | watch descriptor → index scan |
| macOS/FreeBSD | `kqueue` `EVFILT_VNODE` (`KEventWatcher.rs`) | ❌ one **open fd per watched item** (`O_EVTONLY` on mac) | `udata` = watchlist index |
| Windows | `ReadDirectoryChangesW` + IOCP (`WindowsWatcher.rs`) | ✅ natively (`bWatchSubtree=1` on the root handle) | path prefix matching |

Key insight about bun's design: **bun never watches a whole tree**. It only watches files in the import graph plus
their parent directories (discovered during module resolution, `node_modules` excluded). That's why fd-per-file
kqueue is acceptable for them. For a general "watch this whole folder recursively" package (our use case), kqueue
does not scale — macOS needs FSEvents instead. Notably bun does *not* use FSEvents at all.

## Techniques worth copying

1. **Event coalescing with a tiny second wait.** After the first blocking read returns, wait ~100µs more for
   stragglers before dispatching (kqueue: second `kevent` call with 100µs timeout, `KEventWatcher.rs:84`;
   inotify: `ppoll` with 100µs, `INotifyWatcher.rs:252`; Windows: second `GetQueuedCompletionStatus` with
   0 timeout — they note a 1ms timeout actually waits 10ms+). Editors produce bursts (see below); this
   collapses them.

2. **Merge events per watched item before dispatch.** Sort the batch by item index, then bitwise-OR the op flags
   of adjacent events for the same item. Op is a bitflag set: `DELETE | METADATA | RENAME | WRITE | MOVE_TO | CREATE`.

3. **Editors don't "modify" files — they do atomic-save dances.** Preserved verbatim comment from
   `INotifyWatcher.rs:211` (a trace of Replit saving `http.ts`): CREATE tmpfile → OPEN → ATTRIB → MODIFY →
   CLOSE_WRITE → MOVED_FROM tmpfile → MOVED_TO `http.ts`. So `IN_MOVED_TO` must be treated as a content change,
   and rename pairing is genuinely hard (bun admits: "We still don't correctly handle MOVED_FROM && MOVED_TO").

4. **inotify flags they use**: dirs get `IN_EXCL_UNLINK | IN_DELETE | IN_DELETE_SELF | IN_CREATE | IN_MOVE_SELF |
   IN_ONLYDIR | IN_MOVED_TO | IN_MODIFY`; files get the same minus `IN_DELETE/IN_CREATE/IN_ONLYDIR`.
   `IN_EXCL_UNLINK` avoids noise from already-unlinked-but-open files.

5. **Overflow handling is mandatory, not an edge case.**
   - inotify: the read buffer can contain more events than your dispatch batch; they keep a `read_ptr`
     continuation into the buffer instead of dropping events (`INotifyWatcher.rs:53`, hit "under high watching
     load").
   - Windows: `GetQueuedCompletionStatus` returning `nbytes == 0` means RDCW's internal buffer overflowed —
     events are lost but the correct response is **re-arm and continue**, not error out (`WindowsWatcher.rs:341`,
     they had a bug where treating it as shutdown silently killed hot reload).
   - inotify also delivers `IN_Q_OVERFLOW`.

6. **Windows-specific**: the 64KB event buffer and the `OVERLAPPED` struct must live at stable addresses and the
   `OVERLAPPED` must be zeroed or RDCW fails; records are `FILE_NOTIFY_INFORMATION` with `NextEntryOffset`
   chaining and UTF-16 names relative to the watch root; only paths inside the watched root can be watched;
   actions map cleanly: Added/Removed/Modified/RenamedOld/RenamedNew.

7. **Lifecycle bugs they hit that we should design around**:
   - kqueue stores the watchlist index in `udata`; after a swap-remove the moved item's registration still
     carries the old index and must be re-registered (their issue #29524).
   - Stale kqueue events can reference already-evicted indices — bounds-check event indices against the list.
   - Eviction is deferred to a batch (`flush_evictions`) that runs under the same mutex as additions, else a
     window exists where a closed fd is read (`EBADF`).
   - Shutdown: set atomic flag under mutex; the watcher thread checks it after every batch and before invoking
     the callback.

## What we will NOT copy

- The dedicated OS thread + mutex design. Julia's libuv integration (`FDWatcher`, uv handles) lets a normal
  Julia task wait on the kernel fd with **no extra thread and no locking against a callback thread**.
- kqueue fd-per-file on macOS (doesn't scale to whole trees; FSEvents does, and libuv wraps it).
- The import-graph watchlist, path hashing (wyhash), SoA `MultiArrayList`, package_json/loader plumbing — all
  bundler-specific.
- Watching individual files with separate registrations — we watch one root recursively.

# What we learned about Julia's capabilities (experiments)

All experiment code is archived in [`experiments/`][exp-dir] from commit
[`d16cb269`](https://github.com/JuliaPluto/BetterFileWatching.jl/tree/d16cb269acca6574fbab10555563deefd92e4aa6);
results from this machine (macOS, Julia 1.12.6) and Docker `julia:1.12` (Linux aarch64).

## Experiment 1 — recursive watching is one flag away on macOS/Windows ✅

[`01_recursive_uv.jl`][exp-01] + [`RecursiveFolderMonitor.jl`][exp-recursive-folder-monitor]

Julia's `FileWatching.FolderMonitor` calls `uv_fs_event_start(handle, cb, folder, 0)` — flags hardcoded to `0`
([FileWatching.jl:273](https://github.com/JuliaLang/julia/blob/v1.12.6/stdlib/FileWatching/src/FileWatching.jl#L273)).
libuv defines `UV_FS_EVENT_RECURSIVE = 4`, supported on macOS (via FSEvents) and Windows (via RDCW subtree —
the exact same code path node's `fs.watch({recursive: true})` uses).

Copying `FolderMonitor` (~60 lines, ccall-ing the libuv that ships inside Julia) and passing `flags = 4`:

- **macOS, flags=0** (stdlib behavior): only top-level entries reported; nested file events **missing**.
- **macOS, flags=4**: all events reported, with **root-relative paths** (`a/b/nested.txt`), **including files in
  directories created after the watch started** — FSEvents handles new subdirectories automatically.
- **Linux, flags=4**: silently ignored (no error!) — behaves exactly like flags=0. Linux needs its own backend.

Caveat found: libuv collapses FSEvents flags to just `UV_RENAME`/`UV_CHANGE`, and an *append to an existing file*
arrived as `rename` (→ we'd classify "Created") rather than `change`. Event-kind fidelity on macOS is coarse;
paths are reliable. Disambiguation heuristics (stat + small state) can improve this; BetterFileWatching has the
same coarseness today.

## Experiment 2 — raw inotify + FDWatcher works great on Linux ✅

[`02_linux_inotify.jl`][exp-02]

- `inotify_init1` / `inotify_add_watch` via `ccall` into libc: trivial, no dependencies.
- The inotify fd is pollable, so `FileWatching.FDWatcher` (public stdlib API, wraps `uv_poll`) lets a plain
  Julia task `wait()` for readability and then do non-blocking reads. **No dedicated OS thread needed** — this
  is nicer than bun's design and only possible because the kernel object is an fd.
- Per-directory watches + walkdir at startup gives recursion; `IN_CREATE|IN_ISDIR` → add watch dynamically.
- **We reproduced the classic race**: `mkpath("newdir/sub")` created `sub` before the watch on `newdir` landed →
  events silently missed. Fix (validated): after watching a new dir, scan it, watch nested subdirs, and
  synthesize `create` events for entries already present. This implies **at-least-once delivery** (duplicates
  possible), which the API should document.
- Event kinds on Linux are precise: create/modify/close_write/delete/moved_from/moved_to all distinct.

## Experiment 3 — the target API with CancellationTokens works ✅

[`03_api_prototype.jl`][exp-03]

```julia
src = CancellationTokenSource()
watch_task = @async watch_folder(dir, get_token(src)) do event
    @info "changed!" event
end
# ... later:
cancel(src)   # watch_folder cleans up and returns
```

`CancellationTokens.take!(channel, token)` throws `OperationCanceledException` on cancel — exactly the hook we
need to unblock the event loop and tear down the uv handle. Ran cleanly; events mapped to
BetterFileWatching-style `Created`/`Modified`/`Removed` structs with `.path`.

## Experiment 4 — Linux scaling numbers ✅

[`04_linux_stress.jl`][exp-04], tree of 5,101 directories:

- watch setup (walkdir + 5,101 × `inotify_add_watch`): **~160 ms**
- event latency warm: **~2 ms** (first event ~110 ms = Julia JIT, one-time)
- default kernel limit `fs.inotify.max_user_watches` is 128k on modern kernels (was 8,192 on older ones) —
  per-*directory* watches make this a non-issue for realistic trees, but `ENOSPC` should be surfaced clearly.

## Milestone 3 learnings (semantics polish, 2026-07-03)

- **libuv's Windows fs-event mapping**: everything except `FILE_ACTION_MODIFIED` arrives as `UV_RENAME`
  (Added/Removed/RenamedOld/RenamedNew — libuv `win/fs-event.c`). So on Windows a `UV_RENAME` event whose
  path is gone followed *adjacently* by one whose path exists is a true rename pair (RDCW always delivers
  Old,New back-to-back). On macOS FSEvents usually delivers pairs together too but order isn't guaranteed —
  pairing there is best-effort. Hence `RenameHint(path, existed)`: the backend samples `ispath` at event
  time, the batch merge step does the pairing.
- **Duplicate suppression must be per-path-last, not a global seen-set**: dedup by "identical to the last
  event for the same paths" so the Linux rescan duplicates collapse but a rapid create→remove→create still
  delivers all three (a global set would eat the third and leave consumers with wrong state).
- **Coalescing lives best in the API layer**: one blocking `take!`, then `sleep(latency)` (default 10 ms),
  then drain the channel — simpler than bun's per-backend second syscall, works for all backends, and the
  cancellation token still interrupts the blocking take.

## Julia internals we rely on

- Public stdlib API: `FileWatching.FDWatcher`, `FileWatching.FileEvent`.
- Base internals (same ones the FileWatching stdlib itself uses, stable for years but not public API):
  `Base.associate_julia_struct`, `Base.iolock_begin/end`, `Base.eventloop`, `Base.preserve_handle`,
  `Base._sizeof_uv_fs_event`, `Base.uv_error`, `Base._UVError`, `:jl_close_uv`, `:jl_uv_handle_data`.
  Only needed for the macOS/Windows backend. Needs CI across Julia versions (target: 1.10 LTS+).

[exp-dir]: https://github.com/JuliaPluto/BetterFileWatching.jl/tree/d16cb269acca6574fbab10555563deefd92e4aa6/experiments
[exp-01]: https://github.com/JuliaPluto/BetterFileWatching.jl/blob/d16cb269acca6574fbab10555563deefd92e4aa6/experiments/01_recursive_uv.jl
[exp-02]: https://github.com/JuliaPluto/BetterFileWatching.jl/blob/d16cb269acca6574fbab10555563deefd92e4aa6/experiments/02_linux_inotify.jl
[exp-03]: https://github.com/JuliaPluto/BetterFileWatching.jl/blob/d16cb269acca6574fbab10555563deefd92e4aa6/experiments/03_api_prototype.jl
[exp-04]: https://github.com/JuliaPluto/BetterFileWatching.jl/blob/d16cb269acca6574fbab10555563deefd92e4aa6/experiments/04_linux_stress.jl
[exp-recursive-folder-monitor]: https://github.com/JuliaPluto/BetterFileWatching.jl/blob/d16cb269acca6574fbab10555563deefd92e4aa6/experiments/RecursiveFolderMonitor.jl
