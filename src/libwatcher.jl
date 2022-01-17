libwatcher = "/home/paul/Projects/watcher/build/libwatcher.so"

mutable struct Watcher
    cond::Base.AsyncCondition
    chan::Channel{Nothing}
    watcher::Ptr{Nothing}

    dir::String

    Watcher(cond::Base.AsyncCondition, chan::Channel{Nothing}, watcher::Ptr{Nothing}, dir::AbstractString) =
        finalizer(watcher_unsubscribe, new(cond, chan, watcher, dir))
end
Watcher(f::Function, ptr, dir::AbstractString) = Watcher(Base.AsyncCondition(f), ptr, dir)

Base.show(io::IO, w::Watcher) = write(io, "Watcher(\"", w.dir, "\")")

Base.@kwdef struct Options
    ignores::Set{String} = Set{String}()
    backend = "default"
end

function watcher_write_snapshot(dir, snapshot_path)
    @ccall libwatcher.watcher_write_snapshot(dir::Cstring, snapshot_path::Cstring)::Cvoid
end

function watcher_get_events_since(dir, snapshot_path, events)
    @ccall libwatcher.watcher_get_events_since(
        dir::Cstring,
        snapshot_path::Cstring,
        events::Ptr{Nothing},
    )::Cvoid
end

function watcher_subscribe(dir, handle)
    @ccall libwatcher.watcher_subscribe(dir::Cstring, handle::Ptr{Nothing})::Cvoid
end
watcher_subscribe(w::Watcher) = watcher_subscribe(w.dir, w.cond.handle)

function watcher_unsubscribe(dir)
    @ccall libwatcher.watcher_unsubscribe(dir::Cstring)::Cvoid
end

function watcher_unsubscribe(watcher::Watcher)
    if isopen(watcher.cond)
        take!(watcher.chan)
        isopen(watcher.cond) || return

        watcher_unsubscribe(watcher.dir) # FIXME: use watcher instead of dir
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
    options_ptr = @ccall libwatcher.watcher_new_options()::Ptr{Nothing}
    for ignore in options.ignores
        @ccall libwatcher.watcher_options_add_ignore(
            options_ptr::Ptr{Nothing},
            ignore::Cstring,
        )::Ptr{Nothing}
    end
    @ccall libwatcher.watcher_options_set_backend(
        options_ptr::Ptr{Nothing},
        options.backend::Cstring,
    )::Ptr{Nothing}

    options_ptr
end

function watcher_delete_options(options)
    @ccall libwatcher.watcher_delete_options(options::Ptr{Nothing})::Cvoid
end

struct JLEvent
    path::Ptr{Cchar}
    path_length::Csize_t
    is_created::Bool
    is_deleted::Bool
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
    path # TODO
end

mutable struct Events
    size::Csize_t
    events::Ptr{JLEvent}
end
Events() = Events(0, Ptr{JLEvent}())

function _get_events(watcher_ptr)
    events = Events()
    GC.@preserve events watcher_watcher_get_events(
        watcher_ptr,
        Base.pointer_from_objref(events),
    )
    events.events == C_NULL && error("Failed to fetch events from watcher.")

    raw_events = Base.unsafe_wrap(Array, events.events, events.size; own = true)

    map(raw_events) do raw_event
        event = Event(raw_event)
        ccall(:free, Cvoid, (Ptr{Nothing},), raw_event.path)
        event
    end
end

function subscribe(f::Function, dir, options = Options())
    dir = sanitize_path(dir)

    options_ptr = to_options_ptr(options)
    watcher_ptr = watcher_get_watcher(dir, options_ptr)
    watcher_delete_options(options_ptr)

    chan = Channel{Nothing}(1)
    put!(chan, nothing)

    function callback(_)
        try
            take!(chan)
            events = _get_events(watcher_ptr)
            put!(chan, nothing)

            f(events)
        catch err
            @error "something went wrong" err
        end
    end

    cond = Base.AsyncCondition(callback)
    watcher = Watcher(cond, chan, watcher_ptr, dir)

    watcher_subscribe(watcher)

    watcher
end

function unsubscribe(watcher)
    watcher_unsubscribe(watcher)

    nothing
end

function write_snapshot(dir, snapshot_path)
    dir = sanitize_path(dir)

    watcher_write_snapshot(dir, snapshot_path)
end

function get_events_since(dir, snapshot)
    dir = sanitize_path(dir)

    events = Events()
    GC.@preserve events watcher_get_events_since(
        dir,
        snapshot,
        Base.pointer_from_objref(events),
    )
    events.events == C_NULL && error("Failed to get events since for '$snapshot'")

    Base.unsafe_wrap(Array, events.events, events.size; own = true)
end

"Synchronous API"
function watch(f::Function, dir::AbstractString, options = Options())
    dir = sanitize_path(dir)

    options_ptr = to_options_ptr(options)
    watcher_ptr = watcher_get_watcher(dir, options_ptr)
    watcher_delete_options(options_ptr)

    cond = Base.AsyncCondition()
    chan = Channel{Nothing}(1)
    put!(chan, nothing)
    w = Watcher(cond, chan, watcher_ptr, dir)

    task = Task() do
        try
            while isopen(cond)
                wait(cond)

                take!(chan)
                events = _get_events(watcher_ptr)
                put!(chan, nothing)
                f(events)
            end
        finally
            unsubscribe(w)
        end
    end

    watcher_subscribe(w)

    schedule(task)

    try
        wait(task)
    catch
    end

    nothing
end
