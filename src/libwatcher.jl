libwatcher = "/home/paul/Projects/watcher/zig-out/lib/libwatcher.so"

mutable struct Watcher
	cond::Base.AsyncCondition
  watcher::Ptr{Nothing}

  dir::AbstractString
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

function watcher_get_events_since(dir, snapshot_path, callback)
	@ccall libwatcher.watcher_get_events_since(dir::Cstring, snapshot_path::Cstring, callback::Ptr{Nothing})::Cvoid
end

function watcher_subscribe(dir, handle)
	@ccall libwatcher.watcher_subscribe(dir::Cstring, handle::Ptr{Nothing})::Cvoid
end
watcher_subscribe(w::Watcher) = watcher_subscribe(w.dir, w.cond.handle)

function watcher_unsubscribe(dir)
	@ccall libwatcher.watcher_unsubscribe(dir::Cstring)::Cvoid
end
watcher_unsubscribe(w::Watcher) = watcher_unsubscribe(w.dir)

function watcher_get_watcher(dir, options)
  @ccall libwatcher.watcher_get_watcher(dir::Cstring, options::Ptr{Nothing})::Ptr{Nothing}
end

function watcher_watcher_get_events(watcher, events)
  @ccall libwatcher.watcher_watcher_get_events(watcher::Ptr{Nothing}, events::Ptr{Nothing})::Ptr{Nothing}
end

function to_options_ptr(options)
  options_ptr = @ccall libwatcher.watcher_new_options()::Ptr{Nothing}
  for ignore in options.ignores
    @ccall libwatcher.watcher_options_add_ignore(options_ptr::Ptr{Nothing}, ignore::Cstring)::Ptr{Nothing}
  end
  @ccall libwatcher.watcher_options_set_backend(options_ptr::Ptr{Nothing}, options.backend::Cstring)::Ptr{Nothing}

  options_ptr
end

function watcher_delete_options(options)
  @ccall libwatcher.watcher_delete_options(options::Ptr{Nothing})::Cvoid
end

struct JLEvent
	path::Ptr{Int8}
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
  jl_event.is_deleted
)

const global_watchers = Dict{String,Watcher}()

function _subscribe_callback(f)
	function _c_callback(cevents::Ptr{JLEvent}, n_events::Csize_t)
		events = Event[]

		if cevents == C_NULL
			f(Event[])
			return nothing
		end

		for i in 0:n_events-1
			jl_event = Base.unsafe_load(cevents + i * sizeof(JLEvent))
			if jl_event.path_length == 0
        @warn "got path of length 0"
        continue
      end
			push!(events, Event(jl_event))
		end

		@async f(events)

		nothing
	end

	@cfunction($_c_callback, Cvoid, (Ptr{JLEvent}, Csize_t))
end

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
  watcher_watcher_get_events(watcher_ptr, Base.pointer_from_objref(events))
  events.events == C_NULL && error("Failed to fetch events from watcher.")

  Base.unsafe_wrap(Array, events.events, events.size; own=true)
end

function subscribe(f::Function, dir, options=Options())
	dir = sanitize_path(dir)

  options_ptr = to_options_ptr(options)
  watcher_ptr = watcher_get_watcher(dir, options_ptr);
  watcher_delete_options(options_ptr)

  function callback(_)
    try
      events = Event.(_get_events(watcher_ptr))
      f(events)
    catch err
      @error "something went wrong" err
    end
  end

  cond = Base.AsyncCondition(callback)
	watcher = Watcher(cond, watcher_ptr, dir)

	watcher_subscribe(watcher)

	watcher
end

function unsubscribe(watcher)
	watcher_unsubscribe(watcher)

	delete!(global_watchers, watcher.dir)
	nothing
end

function write_snapshot(dir, snapshot_path)
	dir = sanitize_path(dir)

	watcher_write_snapshot(dir, snapshot_path);
end

function get_events_since(dir, snapshot)
	dir = sanitize_path(dir)

	events_ref = Ref{Vector{Event}}(Event[])
	callback = _subscribe_callback() do events
		events_ref[] = events
	end

	GC.@preserve callback watcher_get_events_since(dir, snapshot, callback)

	events_ref[]
end

"Synchronous API"
function watch(f::Function, dir::AbstractString, options=Options())
  dir = sanitize_path(dir)

  options_ptr = to_options_ptr(options)
  watcher_ptr = watcher_get_watcher(dir, options_ptr)
  watcher_delete_options(options_ptr)

  cond = Base.AsyncCondition()
  w = Watcher(cond, watcher_ptr, dir)

  task = Task() do
    try
      while true
	wait(cond)

	events = Event.(_get_events(watcher_ptr))
	f(events)
      end
    finally
      unsubscribe(w)
    end
  end

  watcher_subscribe(w)

  schedule(task)
  wait(task)
end
