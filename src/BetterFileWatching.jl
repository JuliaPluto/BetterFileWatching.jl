module BetterFileWatching

import Deno_jll: deno

import JSON


abstract type FileEvent end

struct AnyEvent <: FileEvent
    paths::Vector{String}
end
struct Accessed <: FileEvent
    paths::Vector{String}
end
struct Created <: FileEvent
    paths::Vector{String}
end
struct Modified <: FileEvent
    paths::Vector{String}
end
struct Renamed <: FileEvent
    paths::Vector{String}
end
struct Removed <: FileEvent
    paths::Vector{String}
end
struct Other <: FileEvent
    paths::Vector{String}
end

# These should match https://docs.deno.com/api/deno/~/Deno.FsEvent
const mapFileEvent = Dict(
    "any" => AnyEvent,
    "access" => Accessed,
    "create" => Created,
    "modify" => Modified,
    "rename" => Renamed,
    "remove" => Removed,
    "other" => Other,
)

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
function watch_folder(on_event::Function, dir::AbstractString="."; ignore_accessed::Bool=true, ignore_dotgit::Bool=true)
    script = """
        const watcher = Deno.watchFs($(JSON.json(dir)));
        for await (const event of watcher) {
            try {
                await Deno.stdout.write(new TextEncoder().encode("\\n" + JSON.stringify(event) + "\\n"));
            } catch(e) {
                console.error("Error while writing changes to stdout", e);
                Deno.exit();
            }
        }
    """

    outpipe = Pipe()

    function on_stdout(str)
        for s in split(str, "\n"; keepempty=false)
            local event_raw = nothing
            event = try
                event_raw = JSON.parse(s)
                T = mapFileEvent[event_raw["kind"]]
                T(String.(event_raw["paths"]))
            catch e
                @warn "Unrecognized file watching event. Please report this to https://github.com/JuliaPluto/BetterFileWatching.jl" event_raw ex=(e,catch_backtrace())
            end
            if !(ignore_accessed && event isa Accessed)
                if !(ignore_dotgit && event isa FileEvent && all(".git" ∈ splitpath(relpath(path, dir)) for path in event.paths))
                    on_event(event)
                end
            end
        end
    end

    deno_proc = open(pipeline(`$(deno()) eval $(script)`; stdout=outpipe))
    atexit(() -> Base.kill(deno_proc))
    watch_task = @async try
        while true
            on_stdout(String(readavailable(outpipe)))
        end
    catch e
        Base.process_running(deno_proc) || Base.kill(deno_proc)
        if !(e isa InterruptException)
            @error "BetterFileWatching error" exception=(e,catch_backtrace())
        end
    end
    
    try wait(watch_task) catch; end
end


function watch_folder(dir::AbstractString="."; kwargs...)::Union{Nothing,FileEvent}
    event = Ref{Union{Nothing,FileEvent}}(nothing)
    task = Ref{Task}()
    task[] = @async watch_folder(dir; kwargs...) do e
        event[] = e
        try
        schedule(task[], InterruptException(); error=true) 
        catch; end
    end
    wait(task[])    
    event[]
end


"""
```julia
watch_file(f::Function, filename::AbstractString)
```

Watch a file recursively for any changes. A [`FileEvent`](@ref) is passed to the callback function `f` when a change occurs.

Use the single-argument `watch_file(filename::AbstractString)` to create a **blocking call** until the file changes (like the FileWatching standard library).

$(_doc_examples(false))

# Differences with the FileWatching stdlib

-   BetterFileWatching.jl is based on [Deno.watchFs](https://doc.deno.land/builtin/stable#Deno.watchFs), made available through the [Deno_jll](https://github.com/JuliaBinaryWrappers/Deno_jll.jl) package.
"""
watch_file(filename::AbstractString; kwargs...) = watch_folder(filename; kwargs...)
watch_file(f::Function, filename::AbstractString; kwargs...) = watch_folder(f, filename; kwargs...)

end
