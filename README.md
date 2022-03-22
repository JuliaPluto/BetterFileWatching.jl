# BetterFileWatching.jl

```julia
watch_folder(f::Function, dir=".")
```

Watch a folder recursively for any changes. Includes changes to file contents. A [`FileEvent`](@ref) is passed to the callback function `f`.

## Examples
=======
```julia
watch_file(f::Function, filename=".")
```

Watch a file for changes. A [`FileEvent`](@ref) is passed to the callback function `f`.

```julia
watch_folder(".") do event
    @info "Something changed!" event
end
```

You can watch a folder asynchronously, and interrupt the task later:

```julia
watch_task = @async watch_folder(".") do event
    @info "Something changed!" event
end

sleep(5)

# stop watching the folder
schedule(watch_task, InterruptException(); error=true)
```

## Snapshots

The library also allow you take snapshots of a directory and read those snapshots later to see exactly which files have been updated/deleted/created.

```julia
options = BetterFileWatching.Options(ignores = Set{String}(["./.git"]))
BetterFileWatching.write_snapshot(dir, snapshot_path; options = options)

# Create some, do some changes, delete some files...

events = BetterFileWatching.get_events_since(dir, snapshot_path; options = options)
```

## Differences with the FileWatching stdlib

`BetterFileWatching.watch_file` is an alternative to `FileWatching.watch_file`. The differences are:
-   We offer an additional callback API (`watch_file(::Function, ::String)`, like the examples above), which means that *handling* events does not block *receiving new events*: we keep listening to changes asynchronously while your callback runs.
-   BetterFileWatching.jl is just a small wrapper around [parcel-bundler/watcher](https://github.com/parcel-bundler/watcher), made available through the [libwatcher_jll](https://github.com/JuliaBinaryWrappers/libwatcher_jll.jl) package. `watcher` is well-tested and widely used.

`BetterFileWatching.watch_folder` is an alternative to `FileWatching.watch_folder`. The differences are, in addition to those mentioned above for `watch_file`:
-   `BetterFileWatching.watch_folder` works _recursively_, i.e. subfolders are also watched.
-   `BetterFileWatching.watch_folder` also watches for changes to the _contents_ of files contained in the folder.

---

In fact, `BetterFileWatching.watch_file` and `BetterFileWatching.watch_folder` are actually just the same function! It handles both files and folders.
