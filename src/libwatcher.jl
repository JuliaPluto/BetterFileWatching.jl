using libwatcher_jll

mutable struct VariableSize{N}
    data::NTuple{N,UInt8}
end
const handle_size = Ref{Int}(-1)

function WatcherHandle()
    if handle_size[] == -1
        handle_size[] = @ccall libwatcher.watcher_watcher_handle_sizeof()::Csize_t
    end

    s = handle_size[]

    VariableSize{s}(Tuple(0 for _ = 1:s))
end

mutable struct Watcher
    cond::Base.AsyncCondition
    chan::Channel{Nothing}
    handle::VariableSize

    dir::String

    Watcher(
        cond::Base.AsyncCondition,
        chan::Channel{Nothing},
        handle::VariableSize,
        dir::AbstractString,
    ) = finalizer(watcher_unsubscribe, new(cond, chan, handle, dir))
end
Watcher(f::Function, handle, dir::AbstractString) =
    Watcher(Base.AsyncCondition(f), handle, dir)

Base.show(io::IO, w::Watcher) = write(io, "Watcher(\"", w.dir, "\")")

Base.@kwdef struct Options
    ignores::Set{String} = Set{String}()
    backend = "default"
end

function watcher_write_snapshot(dir, snapshot_path, options)
    @ccall libwatcher.watcher_write_snapshot(
        dir::Cstring,
        snapshot_path::Cstring,
        options::Ptr{Nothing},
    )::Cvoid
end

function watcher_get_events_since(dir, snapshot_path, events, options)
    @ccall libwatcher.watcher_get_events_since(
        dir::Cstring,
        snapshot_path::Cstring,
        events::Ptr{Nothing},
        options::Ptr{Nothing},
    )::Cvoid
end

function watcher_subscribe(dir, handle, options, watcher_handle)
    @ccall libwatcher.watcher_subscribe(
        dir::Cstring,
        handle::Ptr{Nothing},
        options::Ptr{Nothing},
        watcher_handle::Ptr{Nothing},
    )::Cvoid
end
function watcher_subscribe(w::Watcher, options)
    GC.@preserve w watcher_subscribe(
        w.dir,
        w.cond.handle,
        options,
        Base.pointer_from_objref(w.handle),
    )
end

function watcher_unsubscribe(handle)
    GC.@preserve handle @ccall libwatcher.watcher_unsubscribe(
        Base.pointer_from_objref(handle)::Ptr{Cvoid},
    )::Cvoid
end

function watcher_unsubscribe(watcher::Watcher)
    if isopen(watcher.cond)
        take!(watcher.chan)
        isopen(watcher.cond) || return

        watcher_unsubscribe(watcher.handle)
        Base.close(watcher.cond)
    end

    nothing
end

function watcher_get_watcher(dir, options)
    @ccall libwatcher.watcher_get_watcher(dir::Cstring, options::Ptr{Nothing})::Ptr{Nothing}
end

function watcher_delete_watcher(watcher)
    @ccall libwatcher.watcher_delete_watcher(watcher::Ptr{Nothing})::Cvoid
end

function watcher_watcher_get_events(watcher, events)
    @ccall libwatcher.watcher_watcher_get_events(
        watcher::Ptr{Nothing},
        events::Ptr{Nothing},
    )::Ptr{Nothing}
end

function to_options_ptr(options)
    options = Options(
        ignores = Set{String}(abspath(p) for p in options.ignores),
        backend = options.backend,
    )

    options_ptr = @ccall libwatcher.watcher_new_options()::Ptr{Nothing}
    for ignore in options.ignores
        @ccall libwatcher.watcher_options_add_ignore(
            options_ptr::Ptr{Nothing},
            ignore::Cstring,
        )::Ptr{Nothing}
    end
    GC.@preserve options @ccall libwatcher.watcher_options_set_backend(
        options_ptr::Ptr{Nothing},
        options.backend::Cstring,
    )::Ptr{Nothing}

    options_ptr
end

function watcher_delete_options(options)
    @ccall libwatcher.watcher_delete_options(options::Ptr{Nothing})::Cvoid
end

function watcher_delete_events(events)
    @ccall libwatcher.watcher_delete_events(events::Ptr{Nothing})::Cvoid
end

struct JLEvent
    path::Ptr{Cchar}
    path_length::Csize_t
    is_created::Cuchar
    is_deleted::Cuchar
end

struct Event
    path::String
    is_created::Bool
    is_deleted::Bool
end
Event(jl_event::JLEvent) = Event(
    Base.unsafe_string(jl_event.path, jl_event.path_length),
    jl_event.is_created,
    jl_event.is_deleted,
)

function sanitize_path(path)
    length(path) == 0 && error("path can't be empty")
    isdir(path) || error("path $path should be a directory")
    abspath(path)
end

mutable struct Events
    size::Csize_t
    events::Ptr{JLEvent}

    Events(size, events) = finalizer(
        e -> begin
            watcher_delete_events(Base.pointer_from_objref(e))
        end,
        new(size, events),
    )
end
Events() = Events(0, Ptr{JLEvent}())

function _get_events(watcher_ptr)
    events = Events()
    GC.@preserve events watcher_ptr watcher_watcher_get_events(
        Base.pointer_from_objref(watcher_ptr),
        Base.pointer_from_objref(events),
    )
    events.events == C_NULL && error("Failed to fetch events from watcher.")

    GC.@preserve events begin
        raw_events = Base.unsafe_wrap(Array, events.events, events.size)
        Event.(raw_events)
    end
end

function subscribe(f::Function, dir, options = Options())
    dir = sanitize_path(dir)

    handle = WatcherHandle()

    chan = Channel{Nothing}(1)
    put!(chan, nothing)

    function callback(_)
        try
            take!(chan)
            events = _get_events(handle)
            put!(chan, nothing)

            f(events)
        catch err
            @error "something went wrong" err
        end
    end

    cond = Base.AsyncCondition(callback)
    watcher = Watcher(cond, chan, handle, dir)

    GC.@preserve options begin
        options_ptr = to_options_ptr(options)
        watcher_subscribe(watcher, options_ptr)
        watcher_delete_options(options_ptr)
    end

    watcher
end

function unsubscribe(watcher)
    watcher_unsubscribe(watcher)

    nothing
end

function validate_snapshot_path(path)
    parent_path = abspath(path) |> dirname
    if !isdir(parent_path)
        error("Folder $parent_path does not exist for snapshot file $path")
    end
    length(path) == 0 && error("An empty path is not valid")
end

"""
    write_snapshot(dir::AbstractString, snapshot_path::AbstractString)::Nothing

Writes a snapshot file to snaphot_path from the directory dir. The written snapshot can
then be used with `get_events_since(dir, snapshot_path)` to retrieve the changes.
"""
function write_snapshot(dir, snapshot_path; options = Options())
    dir = sanitize_path(dir)
    validate_snapshot_path(snapshot_path)

    options_ptr = to_options_ptr(options)
    watcher_write_snapshot(dir, snapshot_path, options_ptr)
    watcher_delete_options(options_ptr)

    nothing
end

"""
get_events_since(dir::AbstractString, snapshot_path::AbstractString)::Vector{Event}

"""
function get_events_since(dir, snapshot_path; options = Options())
    dir = sanitize_path(dir)
    validate_snapshot_path(snapshot_path)

    events = Events()
    GC.@preserve events options begin

        options_ptr = to_options_ptr(options)
        watcher_get_events_since(
            dir,
            snapshot_path,
            Base.pointer_from_objref(events),
            options_ptr,
        )
        watcher_delete_options(options_ptr)
        events.events == C_NULL && error("Failed to get events since for '$snapshot_path'")

        Event.(Base.unsafe_wrap(Array, events.events, events.size))
    end
end

"Synchronous API"
function watch_folder_sync(f::Function, dir::AbstractString; options = Options())
    dir = sanitize_path(dir)

    watcher_handle = WatcherHandle()


    cond = Base.AsyncCondition()
    chan = Channel{Nothing}(1)
    put!(chan, nothing)
    w = Watcher(cond, chan, watcher_handle, dir)

    task = Task() do
        try
            while isopen(cond)
                wait(cond)

                take!(chan)
                events = _get_events(watcher_handle)
                put!(chan, nothing)
                f(events)
            end
        finally
            unsubscribe(w)
        end
    end

    GC.@preserve options begin
        options_ptr = to_options_ptr(options)
        watcher_subscribe(w, options_ptr)
        watcher_delete_options(options_ptr)
    end

    schedule(task)

    try
        wait(task)
    catch
    end

    nothing
end
