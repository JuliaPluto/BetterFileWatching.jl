module BetterFileWatching

include("./libwatcher.jl")

abstract type FileEvent end

struct Modified <: FileEvent
    paths::Vector{String}
end
struct Removed <: FileEvent
    paths::Vector{String}
end
struct Created <: FileEvent
    paths::Vector{String}
end
struct Accessed <: FileEvent
    paths::Vector{String}

    function Accessed(p)
        @warn "Accessed is deprecated and will be removed in the following versions."
    end
end

function convert_to_deno_events(events::Vector{Event})
    reduce(events; init=(; modified=Modified(String[]), removed=Removed(String[]), created=Created(String[]))) do acc, event
        if event.is_created
            push!(acc.created.paths, event.path)
        elseif event.is_deleted
            push!(acc.removed.paths, event.path)
        else
            push!(acc.modified.paths, event.path)
        end

        acc
    end
end

export watch_folder, watch_file

function _doc_examples(folder)
    f = folder ? "folder" : "file"
    args = folder ? "\".\"" : "\"file.txt\""
    """
    # Example

    ```julia
    watch_$(f)($(args)) do event
        @info "Something changed!" event
    end
    ```

    You can watch a $(f) asynchronously, and interrupt the task later:

    ```julia
    watch_task = @async watch_$(f)($(args)) do event
        @info "Something changed!" event
    end

    sleep(5)

    # stop watching the $(f)
    schedule(watch_task, InterruptException(); error=true) 
    ```
    """
end

"""
```julia
watch_folder(f::Function, dir=".")
```

Watch a folder recursively for any changes. Includes changes to file contents. A [`FileEvent`](@ref) is passed to the callback function `f`.

Use the single-argument `watch_folder(dir::AbstractString=".")` to create a **blocking call** until the folder changes (like the FileWatching standard library).

$(_doc_examples(true))

# Differences with the FileWatching stdlib

-   `BetterFileWatching.watch_folder` works _recursively_, i.e. subfolders are also watched.
-   `BetterFileWatching.watch_folder` also watching file _contents_ for changes.
-   BetterFileWatching.jl is based on [Deno.watchFs](https://doc.deno.land/builtin/stable#Deno.watchFs), made available through the [Deno_jll](https://github.com/JuliaBinaryWrappers/Deno_jll.jl) package.
"""
function watch_folder(on_event::Function, dir::AbstractString="."; ignore_accessed::Union{Bool,Nothing}=nothing, ignore_dotgit::Bool=true)
    # blocking version with a callback
    if ignore_accessed !== nothing
        @warn "ignore_accessed is deprecated and will be removed in the coming versions."
    end

    watch(dir) do events
        events = convert_to_deno_events(events)
        length(events.modified.paths) > 0 && on_event(events.modified)
        length(events.created.paths) > 0 && on_event(events.created)
        length(events.removed.paths) > 0 && on_event(events.removed)
    end
end


function watch_folder(dir::AbstractString="."; kwargs...)::Union{Nothing,FileEvent}
    # blocking without callback
end

"""
```julia
watch_file(f::Function, filename::AbstractString)
```

Watch a folderfile recursively for any changes. A [`FileEvent`](@ref) is passed to the callback function `f` when a change occurs.

Use the single-argument `watch_file(filename::AbstractString)` to create a **blocking call** until the file changes (like the FileWatching standard library).

$(_doc_examples(false))

# Differences with the FileWatching stdlib

-   BetterFileWatching.jl is based on [Deno.watchFs](https://doc.deno.land/builtin/stable#Deno.watchFs), made available through the [Deno_jll](https://github.com/JuliaBinaryWrappers/Deno_jll.jl) package.
"""
watch_file(filename::AbstractString; kwargs...) = watch_folder(filename; kwargs...)
watch_file(f::Function, filename::AbstractString; kwargs...) = watch_folder(f, filename; kwargs...)

end
