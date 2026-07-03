# Shared plumbing between the backends and the public API: channel helpers,
# ignore-predicate normalization, and the batch step (coalescing, duplicate
# suppression, rename pairing) that sits between backend channels and the
# user callback.

# `put!` that never throws: the channel may be closed by a concurrent teardown.
function _offer!(ch::Channel, x)
    try
        put!(ch, x)
    catch
    end
    nothing
end

# ignore predicates get root-relative paths with '/' separators on all platforms
_normslash(p::AbstractString) = Sys.iswindows() ? replace(p, '\\' => '/') : String(p)
_isignored(ignore, rel::AbstractString) = ignore !== nothing && rel != "" && ignore(_normslash(rel))::Bool

# ─── batching ────────────────────────────────────────────────────────────────

# Internal pre-event from the uv backend. libuv flagged `path` as UV_RENAME,
# which means appeared / disappeared / renamed — and on macOS sometimes a
# plain content change, since FSEvents flags get collapsed. `existed` is
# `ispath(path)` sampled when the event fired. Adjacent hint pairs get
# stitched into `Renamed` by `_merge_batch`; singles degrade to
# Created/Removed by existence. (On Windows this pairing is reliable: libuv
# maps RDCW's RenamedOld/RenamedNew — always delivered adjacently — to
# UV_RENAME. On macOS FSEvents usually delivers the pair together too, but
# order isn't guaranteed, so it's best-effort there.)
struct RenameHint
    path::String
    existed::Bool
end

# Block for one message, then give stragglers `latency` seconds to arrive and
# drain everything queued. Editors produce bursts (atomic-save dances); bun
# uses the same wait-a-tiny-second-time trick to collapse them into one batch.
function _collect_batch!(batch::Vector{Any}, ch::Channel, token, latency::Real)
    empty!(batch)
    push!(batch, token === nothing ? take!(ch) : take!(ch, token))
    latency > 0 && sleep(latency)
    while isready(ch)
        push!(batch, take!(ch))
    end
    return batch
end

# Merge a batch: pair rename hints, and drop an event when the previous event
# for the same path(s) was identical. Duplicates are inherent to at-least-once
# delivery — the Linux new-directory rescan synthesizes Created events that
# the kernel may also report — but a genuine create → remove → create must
# survive, so we compare against the last event per path, not a global set.
function _merge_batch(batch::Vector{Any})
    out = FileEvent[]
    last_for = Dict{Vector{String},FileEvent}()
    i = firstindex(batch)
    while i <= lastindex(batch)
        x = batch[i]
        event = if x isa RenameHint
            next = i < lastindex(batch) ? batch[i+1] : nothing
            if !x.existed && next isa RenameHint && next.existed && next.path != x.path
                i += 1   # consume the pair
                Renamed([x.path, next.path])
            elseif x.existed
                Created([x.path])
            else
                Removed([x.path])
            end
        else
            x::FileEvent
        end
        if get(last_for, event.paths, nothing) != event
            push!(out, event)
            last_for[event.paths] = event
        end
        i += 1
    end
    return out
end
