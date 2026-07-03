# Experiment 3: prototype of the actual package API on top of experiment 01,
# with CancellationTokens.jl for stopping (replacing BetterFileWatching's
# `schedule(task, InterruptException(); error=true)` hack).
#
#   watch_folder(callback, dir, token)
#
# Run (macOS/Windows): julia --project=experiments experiments/03_api_prototype.jl

using CancellationTokens
using FileWatching: FileEvent

include(joinpath(@__DIR__, "RecursiveFolderMonitor.jl"))

# ─── BetterFileWatching-compatible event types ───────────────────────────────

abstract type WatchEvent end
struct Created  <: WatchEvent; paths::Vector{String}; end
struct Modified <: WatchEvent; paths::Vector{String}; end
struct Removed  <: WatchEvent; paths::Vector{String}; end
struct Renamed  <: WatchEvent; paths::Vector{String}; end

# libuv only distinguishes RENAME (create/delete/rename) vs CHANGE (content).
# Disambiguate RENAME by statting: path exists → Created, gone → Removed.
function to_event(root::String, fname::String, ev::FileEvent)
    full = joinpath(root, fname)
    if ev.changed
        return Modified([full])
    elseif ispath(full)
        return Created([full])   # or Renamed-target; indistinguishable without pairing
    else
        return Removed([full])
    end
end

# ─── the API ─────────────────────────────────────────────────────────────────

"""
    watch_folder(f, dir=".", token=nothing)

Recursively watch `dir`, calling `f(event)` for every filesystem event.
Blocks until `token` is cancelled (or forever if no token is given).
"""
function watch_folder(f::Function, dir::AbstractString=".", token=nothing)
    root = abspath(dir)
    mon = RecursiveFolderMonitor(root)
    try
        while true
            # take!(ch, token) throws OperationCanceledException on cancel
            msg = token === nothing ? take!(mon.channel) : take!(mon.channel, token)
            msg isa Exception && throw(msg)
            fname, ev = msg
            f(to_event(root, fname, ev))
        end
    catch e
        e isa OperationCanceledException || rethrow()
    finally
        close(mon)
    end
    return nothing
end

# ─── demo ────────────────────────────────────────────────────────────────────

root = mktempdir()
mkpath(joinpath(root, "sub"))

src = CancellationTokenSource()
seen = Channel{Any}(Inf)

watch_task = @async watch_folder(root, get_token(src)) do event
    put!(seen, event)
end

sleep(1.0)
write(joinpath(root, "sub", "hello.txt"), "hi")
sleep(0.5)
open(io -> write(io, "more"), joinpath(root, "sub", "hello.txt"), "a")
sleep(0.5)
rm(joinpath(root, "sub", "hello.txt"))
sleep(1.0)

cancel(src)
wait(watch_task)
println("watch_folder returned cleanly after cancel  :)")

close(seen)
for event in collect(seen)
    println("  ", event)
end
