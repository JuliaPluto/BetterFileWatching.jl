# BetterFileWatching.jl

[![Julia tests](https://github.com/JuliaPluto/BetterFileWatching.jl/actions/workflows/Test.yml/badge.svg)](https://github.com/JuliaPluto/BetterFileWatching.jl/actions/workflows/Test.yml)

```julia
watch_folder(f::Function, dir=".")
```

Watch a folder recursively for any changes. Includes changes to file contents. A `FileEvent` is passed to the callback function `f`.

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

`Created`, `Modified`, `Removed`, and `Other` have a `.path::String` field with the absolute path of the file or folder that changed. 

`Renamed` has `.from::String` and `.to::String` fields for the rename. 

You can use `paths_tuple(event)` to get a tuple with all involved paths (so 1 or 2 paths). Use `collect` if you need a vector.

The event *kinds* might be off on macOS: an append to an existing file may give `Created`.

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
cancel(src)
```

There is also an `ignore` keyword to skip subtrees like `.git`. It is a predicate on root-relative paths (always with `/` separators); matching paths are dropped, and on Linux, matching folders are not even watched. This example ignores every `.git` folder in the tree, however deep:

```julia
watch_folder(".", token; ignore = rel -> ".git" in split(rel, "/")) do event
    # ...
end
```

# Wait for a single event

You can also call `watch_folder(path::String)` or `watch_file(path::String)` without a callback function. The function will wait for the first event, and return it.

# How it works

BetterFileWatching.jl is written in Julia without binary (JLL) dependencies. It uses different OS API depending on the platform:

| Platform | Mechanism |
|---|---|
| macOS | FSEvents, through the libuv that ships inside Julia — recursion is a libuv flag (`UV_FS_EVENT_RECURSIVE`). _(The FileWatching stdlib does not pass this flag.)_ |
| Windows | `ReadDirectoryChangesW` with subtree watching, through the same libuv API as MacOS. |
| Linux | raw `inotify` via `ccall`, one watch per directory (registered dynamically as directories appear), drained by a Julia task via `FileWatching.FDWatcher` — no extra OS thread |

# Differences with the FileWatching stdlib

`BetterFileWatching.watch_folder` is an alternative to `FileWatching.watch_folder`. The differences are, in addition to those mentioned above for `watch_file`:
-   `BetterFileWatching.watch_folder` works _recursively_, i.e. subfolders are also watched — including folders created after the watch started.
-   `BetterFileWatching.watch_folder` also watches for changes to the _contents_ of files contained in the folder.


`BetterFileWatching.watch_file` is an alternative to `FileWatching.watch_file`. The differences are:
-   We offer an additional callback API (`watch_file(::Function, ::String)`, like the examples above), which means that *handling* events does not block *receiving new events*: we keep listening to changes asynchronously while your callback runs.
-   `watch_file` understands the delete/recreate and atomic-save behaviour from code editors, because the parent directory is watched internally.


# How this package was created (with AI)

Versions ≤ 0.1 were a small wrapper around `Deno.watchFs`, running Deno (~30 MB via Deno_jll) as a subprocess, written by Fons and Paul. This worked relatively well (recursive file watching yay!) but not 100% reliable.

Paul worked on a wrapper around `@parcel/watcher` ([PR](https://github.com/JuliaPluto/BetterFileWatching.jl/pull/2)), but there were a couple issues that were too hard to fix, so this approach was abandoned.

Version 1.0.0 is a complete rewrite by AI 🤖 to work without dependencies and without subprocess, inspired by [bun's file watcher](https://github.com/oven-sh/bun/tree/main/src/watcher). Fons reviewed the package as a whole, but the code is not completely reviewed by him, because he does not understand the underlying API. 


<details>
<summary>AI code writing process</summary>


1. AI studied how [bun's file watcher](https://github.com/oven-sh/bun/tree/main/src/watcher) works on each OS, and wrote down the tricks and pitfalls worth copying in [LEARNINGS.md](LEARNINGS.md).
2. AI validated the risky parts (recursive libuv watching, raw inotify with dynamic directory registration) in small standalone scripts, archived in the [`experiments/` snapshot](https://github.com/JuliaPluto/BetterFileWatching.jl/tree/d16cb269acca6574fbab10555563deefd92e4aa6/experiments).
3. AI wrote an [implementation plan](https://github.com/JuliaPluto/BetterFileWatching.jl/blob/d16cb269acca6574fbab10555563deefd92e4aa6/PLAN.md) and worked through it.

</details>


Even though it's an AI who wrote the current code, we would still love to hear your feedback, and we will reply as humans. :)


