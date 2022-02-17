# BetterFileWatching.jl

```julia
watch_folder(f::Function, dir=".")
```

Watch a folder recursively for any changes. Includes changes to file contents. A [`FileEvent`](@ref) is passed to the callback function `f`.

## Examples

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

-   `BetterFileWatching.watch_folder` works _recursively_, i.e. subfolders are also watched.
-   `BetterFileWatching.watch_folder` also watching file _contents_ for changes.
-   BetterFileWatching.jl is just a wrapper around a port of [parcel-bundler/watcher](https://github.com/parcel-bundler/watcher) to Julia (available on [JuliaPluto/watcher](https://github.com/JuliaPluto/watcher))

