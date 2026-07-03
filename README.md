# BetterFileWatching.jl

[![Julia tests](https://github.com/JuliaPluto/BetterFileWatching.jl/actions/workflows/Test.yml/badge.svg)](https://github.com/JuliaPluto/BetterFileWatching.jl/actions/workflows/Test.yml)

```julia
watch_folder(f::Function, dir=".")
```

Watch a folder recursively for any changes. Includes changes to file contents. A [`FileEvent`](@ref) is passed to the callback function `f`.

```julia
watch_file(f::Function, filename)
```

Watch a file for changes. A [`FileEvent`](@ref) is passed to the callback function `f`.


### `FileEvent`
The object passed to the callback function `f` is a `FileEvent`. This is a supertype, with the following subtypes:

```
julia> BetterFileWatching.FileEvent |> subtypes
5-element Vector{Any}:
 BetterFileWatching.Created
 BetterFileWatching.Modified
 BetterFileWatching.Other
 BetterFileWatching.Removed
 BetterFileWatching.Renamed
```

`Created`, `Modified`, `Removed`, and `Other` each have a `.path::String` field with the absolute path of the file or folder that changed. `Renamed` has `.from::String` and `.to::String` fields when the OS lets us pair the rename. Use `paths_tuple(event)` to handle both shapes uniformly: it returns `(event.path,)` for single-path events and `(event.from, event.to)` for renames.

Event *kinds* are best-effort: precise on Linux and Windows, coarser on macOS (an append to an existing file may surface as `Created`). Event paths are always reliable. Delivery is at-least-once, so make your callback idempotent.

# Example

```julia
watch_folder(".") do event
    @info "Something changed!" event
end
```

You can watch a folder asynchronously, and stop it later with a [CancellationTokens.jl](https://github.com/JuliaPluto/CancellationTokens.jl) token:

```julia
using BetterFileWatching, CancellationTokens

src = CancellationTokenSource()

watch_task = @async watch_folder(".", get_token(src)) do event
    @info "Something changed!" event
end

sleep(5)

# stop watching the folder
cancel(src)   # watch_folder cleans up and returns
```

There is also an `ignore` keyword to skip subtrees like `.git`. It is a predicate on root-relative paths (always with `/` separators); matching paths are dropped, and on Linux, matching folders are not even watched. This example ignores every `.git` folder in the tree, however deep:

```julia
watch_folder(".", token; ignore = rel -> ".git" in splitpath(rel)) do event
    # ...
end
```

# How it works

BetterFileWatching.jl is pure Julia, with zero binary dependencies:

| Platform | Mechanism |
|---|---|
| macOS | FSEvents, through the libuv that ships inside Julia — recursion is a libuv flag (`UV_FS_EVENT_RECURSIVE`) that the FileWatching stdlib just never passes |
| Windows | `ReadDirectoryChangesW` with subtree watching, through the same libuv call |
| Linux | raw `inotify` via `ccall`, one watch per directory (registered dynamically as directories appear), drained by a normal Julia task via `FileWatching.FDWatcher` — no extra OS thread |

# Differences with the FileWatching stdlib

`BetterFileWatching.watch_file` is an alternative to `FileWatching.watch_file`. The differences are:
-   We offer an additional callback API (`watch_file(::Function, ::String)`, like the examples above), which means that *handling* events does not block *receiving new events*: we keep listening to changes asynchronously while your callback runs.
-   `watch_file` keeps working across the delete/recreate and atomic-save dances editors do, because the parent directory is watched internally.

`BetterFileWatching.watch_folder` is an alternative to `FileWatching.watch_folder`. The differences are, in addition to those mentioned above for `watch_file`:
-   `BetterFileWatching.watch_folder` works _recursively_, i.e. subfolders are also watched — including folders created after the watch started.
-   `BetterFileWatching.watch_folder` also watches for changes to the _contents_ of files contained in the folder.

# How this package was created

Version 0.2 is a complete rewrite! Versions ≤ 0.1 were a small wrapper around `Deno.watchFs`, running Deno (~30 MB via Deno_jll) as a subprocess. The rewrite keeps (almost) the same API, but is pure Julia: no subprocess, no binary dependencies.

The rewrite was made with the help of AI 🤖 — Claude wrote most of the code and docs, guided by tests and review. The process:

1.  We studied how [bun's file watcher](https://github.com/oven-sh/bun/tree/main/src/watcher) works on each OS, and wrote down the tricks and pitfalls worth copying in [LEARNINGS.md](LEARNINGS.md).
2.  We validated the risky parts (recursive libuv watching, raw inotify with dynamic directory registration) in small standalone scripts, archived in the [`experiments/` snapshot](https://github.com/JuliaPluto/BetterFileWatching.jl/tree/d16cb269acca6574fbab10555563deefd92e4aa6/experiments).
3.  We wrote an [implementation plan](https://github.com/JuliaPluto/BetterFileWatching.jl/blob/d16cb269acca6574fbab10555563deefd92e4aa6/PLAN.md).
4.  The rewrite was prototyped as a separate package, and then merged back into BetterFileWatching.jl. The original test suite still passes, ensuring compatibility.
