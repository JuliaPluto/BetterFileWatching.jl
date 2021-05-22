module BetterFileWatching

using Deno_jll

import JSON


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


export watch_folder, Modified, Removed, Created, FileEvent

"""
```julia
watch_folder(f::Function, dir=".")
```

Watch a folder recursively for any changes. Includes changes to file contents. A [`FileEvent`](@ref) is passed to the callback function `f`.

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

-   `BetterFileWatching.watch_folder` works _recursively_, i.e. subfolders are also watched.
-   `BetterFileWatching.watch_folder` also watching file _contents_ for changes.
-   BetterFileWatching.jl is based on [Deno.watchFs](https://doc.deno.land/builtin/stable#Deno.watchFs), made available through the [Deno_jll](https://github.com/JuliaBinaryWrappers/Deno_jll.jl) package.
"""
function watch_folder(on_event::Function, dir=".")
    script = """
        const watcher = Deno.watchFs($(JSON.json(dir)));
        for await (const event of watcher) {
            try {
                await Deno.stdout.write(new TextEncoder().encode("\\n" + JSON.stringify(event) + "\\n"));
            } catch(e) {
                Deno.exit();
            }
        }
    """

    outpipe = Pipe()

    function on_stdout(str)
        for s in split(str, "\n"; keepempty=false)
            event = JSON.parse(s)

            if event["kind"] == "modify"
                Modified(String.(event["paths"]))
            elseif event["kind"] == "create"
                Created(String.(event["paths"]))
            elseif event["kind"] == "remove"
                Removed(String.(event["paths"]))
            else
                @error "Unrecognized event!" event
            end |> on_event
        end
    end

    deno_task = @async run(pipeline(`$(deno()) eval $(script)`; stdout=outpipe))
    watch_task = @async try
        sleep(.1)
        while true
            on_stdout(String(readavailable(outpipe)))
        end
    catch e
        if !istaskdone(deno_task)
            schedule(deno_task, e; error=true)
        end
    end
    
    try
        wait(watch_task)
    catch e
        # @error "Oops" exception=(e,catch_backtrace())
        
    end
end


function watch_folder(dir::String=".")::FileEvent
    event = Ref{FileEvent}()
    task = Ref{Task}()
    task[] = @async watch_folder(dir) do e
        event[] = e
        schedule(task[], InterruptException(); error=true) 
    end
    wait(task[])    
    return event[]
end

end # module
