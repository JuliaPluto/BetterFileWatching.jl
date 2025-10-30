# BetterFileWatching.jl

```julia
watch_folder(f::Function, dir=".")
```

Watch a folder recursively for any changes. Includes changes to file contents. A [`FileEvent`](@ref) is passed to the callback function `f`.

```julia
watch_file(f::Function, filename=".")
```

Watch a file for changes. A [`FileEvent`](@ref) is passed to the callback function `f`.


### `FileEvent`
The object passed to the callback function `f` is a `FileEvent`. This is a supertype, with the following subtypes:

```
julia> BetterFileWatching.FileEvent |> subtypes
7-element Vector{Any}:
 BetterFileWatching.Accessed
 BetterFileWatching.AnyEvent
 BetterFileWatching.Created
 BetterFileWatching.Modified
 BetterFileWatching.Other
 BetterFileWatching.Removed
 BetterFileWatching.Renamed
```

Each of these types as a `.paths` field, which is a vector of strings. This is the path of the file or folder that changed. In practice, the `AnyEvent` and `Other` occur only rarely, as a fallback when the specific event type is not known.

# Example

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

# Differences with the FileWatching stdlib

`BetterFileWatching.watch_file` is an alternative to `FileWatching.watch_file`. The differences are:
-   We offer an additional callback API (`watch_file(::Function, ::String)`, like the examples above), which means that *handling* events does not block *receiving new events*: we keep listening to changes asynchronously while your callback runs.
-   BetterFileWatching.jl is just a small wrapper around [`Deno.watchFs`](https://doc.deno.land/builtin/stable#Deno.watchFs), made available through the [Deno_jll](https://github.com/JuliaBinaryWrappers/Deno_jll.jl) package. `Deno.watchFs` is well-tested and widely used.

`BetterFileWatching.watch_folder` is an alternative to `FileWatching.watch_folder`. The differences are, in addition to those mentioned above for `watch_file`:
-   `BetterFileWatching.watch_folder` works _recursively_, i.e. subfolders are also watched.
-   `BetterFileWatching.watch_folder` also watches for changes to the _contents_ of files contained in the folder.

---

In fact, `BetterFileWatching.watch_file` and `BetterFileWatching.watch_folder` are actually just the same function! It handles both files and folders.