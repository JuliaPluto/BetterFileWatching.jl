"""
    BetterFileWatching

Native, recursive, callback-based file watching for Julia. No subprocess, no
binary dependencies — just the OS facilities that ship inside Julia's libuv
(macOS, Windows) plus raw inotify (Linux).

```julia
using BetterFileWatching, CancellationTokens

src = CancellationTokenSource()
watch_task = @async watch_folder(".", get_token(src)) do event
    @info "Something changed!" event
end

# ... later:
cancel(src)   # watch_folder cleans up and returns
```
"""
module BetterFileWatching

using CancellationTokens: CancellationToken, CancellationTokenSource,
    OperationCanceledException, get_token, cancel

export watch_folder, watch_file,
    FileEvent, Created, Modified, Removed, Renamed, Other

# ─── event types ─────────────────────────────────────────────────────────────

"""
Abstract supertype of all watch events. `Created`, `Modified`, `Removed`, and
`Other` each have a `path::String` field with the absolute path they concern.
`Renamed` has `from::String` and `to::String` fields.

Event *kinds* are best-effort and platform-dependent: precise on Linux and
Windows, coarser on macOS (where e.g. an append to an existing file may
surface as `Created`). Delivery is at-least-once: duplicates are possible,
consumers should be idempotent.
"""
abstract type FileEvent end

"A file or directory appeared."
struct Created <: FileEvent
    path::String
end

"File contents or metadata changed."
struct Modified <: FileEvent
    path::String
end

"A file or directory was deleted."
struct Removed <: FileEvent
    path::String
end

"A paired rename from one absolute path to another was observed."
struct Renamed <: FileEvent
    from::String
    to::String
end

"""
Fallback event. Currently emitted when the kernel event queue overflowed:
some events were lost and `path` is the watch root — rescan if you need exact
state.
"""
struct Other <: FileEvent
    path::String
end

_event_key(e::FileEvent) = e.path
_event_key(e::Renamed) = (e.from, e.to)
_event_involves(e::FileEvent, path::String) = e.path == path
_event_involves(e::Renamed, path::String) = e.from == path || e.to == path

Base.:(==)(a::FileEvent, b::FileEvent) = typeof(a) === typeof(b) && _event_key(a) == _event_key(b)
Base.hash(e::FileEvent, h::UInt) = hash(_event_key(e), hash(typeof(e), h))

include("common.jl")
include("backend_uv.jl")
include("backend_inotify.jl")

const Backend = Sys.islinux() ? InotifyBackend : UVBackend

# ─── public API ──────────────────────────────────────────────────────────────

"""
    watch_folder(f::Function, dir=".", token::CancellationToken; ignore=nothing, latency=0.01)
    watch_folder(f::Function, dir=".")

Watch `dir` (recursively!) for changes, calling `f(event::FileEvent)` for
every event. Blocks until `token` is cancelled, then cleans up and returns
`nothing`. Without a token it blocks forever.

`ignore` is an optional predicate on root-relative paths (always
'/'-separated): events for matching paths are dropped, and on Linux matching
directories are not even watched. For example,
`ignore = rel -> ".git" in splitpath(rel)` skips every `.git` folder in the
tree (and its contents), however deep.

`latency` is the coalescing window in seconds: after the first event arrives,
we wait this long for stragglers, then merge the batch — exact duplicates are
suppressed and rename pairs are stitched into `Renamed(from, to)` where the
OS allows. Editors save files in bursts (write-tmpfile-then-rename dances);
the window collapses those into fewer, better events. Set `latency = 0` to
dispatch every event immediately.

Events for paths inside directories that are *created after the watch starts*
are included. Delivery is at-least-once; event kinds are best-effort
(see [`FileEvent`](@ref)).
"""
function watch_folder(
    f::Function,
    dir::AbstractString = ".",
    token::Union{Nothing,CancellationToken} = nothing;
    ignore::Union{Nothing,Function} = nothing,
    latency::Real = 0.01,
)
    _watch(f, String(abspath(dir)), token; recursive = true, ignore, latency)
end

"""
    watch_file(f::Function, path, token::CancellationToken)
    watch_file(f::Function, path)

Like [`watch_folder`](@ref), but only reports events about the single file at
`path`. Internally the parent directory is watched (non-recursively), so this
keeps working across the delete/recreate and atomic-save dances editors do.
"""
function watch_file(
    f::Function,
    path::AbstractString,
    token::Union{Nothing,CancellationToken} = nothing;
    latency::Real = 0.01,
)
    target = String(abspath(path))
    _watch(f, dirname(target), token;
        recursive = false, ignore = nothing, filter_path = target, latency)
end

"""
    watch_folder(dir=".")
    watch_file(path)

Legacy blocking API (BetterFileWatching ≤ 0.1, mirroring the FileWatching
stdlib): block until one event occurs, and return it.
"""
function watch_folder(dir::AbstractString = "."; kwargs...)
    _watch_one(watch_folder, dir; kwargs...)
end

function watch_file(path::AbstractString; kwargs...)
    _watch_one(watch_file, path; kwargs...)
end

function _watch_one(watch::Function, path::AbstractString; kwargs...)
    src = CancellationTokenSource()
    event = Ref{Union{Nothing,FileEvent}}(nothing)
    watch(path, get_token(src); kwargs...) do e
        if event[] === nothing
            event[] = e
            cancel(src)
        end
    end
    return event[]
end

function _watch(
    f::Function,
    root::String,
    token::Union{Nothing,CancellationToken};
    recursive::Bool,
    ignore::Union{Nothing,Function},
    latency::Real,
    filter_path::Union{Nothing,String} = nothing,
)
    isdir(root) || throw(ArgumentError("Not a directory: $root"))
    backend = Backend(root; recursive, ignore)
    batch = Any[]
    try
        while true
            _collect_batch!(batch, backend.channel, token, latency)
            for msg in batch
                msg isa Exception && throw(msg)
            end
            for event in _merge_batch(batch)
                if filter_path !== nothing
                    _event_involves(event, filter_path) || continue
                end
                f(event)
            end
        end
    catch e
        e isa OperationCanceledException || rethrow()
    finally
        close(backend)
    end
    return nothing
end

end # module
