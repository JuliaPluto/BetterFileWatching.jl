# Backend for Linux: raw inotify via ccall into libc. inotify is not
# recursive, so we keep one watch per directory: a full scan at startup and
# dynamic registration when directories appear. The inotify fd is pollable,
# so a plain Julia task waits on it through FileWatching.FDWatcher (uv_poll)
# and drains it with non-blocking reads — no dedicated OS thread.
#
# Design notes borrowed from bun's INotifyWatcher (see LEARNINGS.md):
# IN_EXCL_UNLINK to cut noise, treat MOVED_TO as appearance (editors
# atomic-save via rename), handle queue overflow by resyncing instead of
# dying, and pair MOVED_FROM/MOVED_TO by cookie within a batch.

using FileWatching: FDWatcher

# ─── constants (linux/inotify.h) ─────────────────────────────────────────────
const IN_NONBLOCK    = Cint(0o4000)
const IN_CLOEXEC     = Cint(0o2000000)

const IN_MODIFY      = 0x00000002 % UInt32
const IN_ATTRIB      = 0x00000004 % UInt32
const IN_CLOSE_WRITE = 0x00000008 % UInt32
const IN_MOVED_FROM  = 0x00000040 % UInt32
const IN_MOVED_TO    = 0x00000080 % UInt32
const IN_CREATE      = 0x00000100 % UInt32
const IN_DELETE      = 0x00000200 % UInt32
const IN_DELETE_SELF = 0x00000400 % UInt32
const IN_MOVE_SELF   = 0x00000800 % UInt32
const IN_Q_OVERFLOW  = 0x00004000 % UInt32
const IN_IGNORED     = 0x00008000 % UInt32
const IN_ONLYDIR     = 0x01000000 % UInt32
const IN_EXCL_UNLINK = 0x04000000 % UInt32
const IN_ISDIR       = 0x40000000 % UInt32

const DIR_MASK = IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO |
                 IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_ONLYDIR | IN_EXCL_UNLINK

# ─── backend ─────────────────────────────────────────────────────────────────

mutable struct InotifyBackend
    fd::Cint
    const fdw::FDWatcher
    const root::String
    const ignore::Union{Nothing,Function}
    const recursive::Bool
    const channel::Channel{Any}
    const wd_to_dir::Dict{Cint,String}
    const dir_to_wd::Dict{String,Cint}
    @atomic closed::Bool

    function InotifyBackend(root::String; recursive::Bool, ignore::Union{Nothing,Function})
        fd = ccall(:inotify_init1, Cint, (Cint,), IN_NONBLOCK | IN_CLOEXEC)
        if fd < 0
            err = Libc.errno()
            msg = err == Libc.EMFILE ?
                " (too many inotify instances; see fs.inotify.max_user_instances)" : ""
            throw(Base.IOError("inotify_init1 failed: $(Libc.strerror(err))$msg", -err))
        end
        fdw = try
            FDWatcher(RawFD(fd), true, false)   # readable, not writable
        catch
            ccall(:close, Cint, (Cint,), fd)
            rethrow()
        end
        this = new(fd, fdw, root, ignore, recursive, Channel{Any}(Inf),
            Dict{Cint,String}(), Dict{String,Cint}(), false)
        try
            _add_watch!(this, root)
            recursive && _watch_tree!(this, root, nothing)
        catch
            close(this)
            rethrow()
        end
        errormonitor(Threads.@spawn _pump(this))
        return this
    end
end

function Base.close(w::InotifyBackend)
    (@atomicswap w.closed = true) && return nothing   # idempotent
    close(w.fdw)                     # wakes the pump task with EOFError
    ccall(:close, Cint, (Cint,), w.fd)
    close(w.channel)
    return nothing
end

# ─── watch registration ──────────────────────────────────────────────────────

function _add_watch!(w::InotifyBackend, dir::String)
    wd = ccall(:inotify_add_watch, Cint, (Cint, Cstring, UInt32), w.fd, dir, DIR_MASK)
    if wd < 0
        err = Libc.errno()
        # The dir may be gone already (watch registration races with deletion) —
        # that's normal churn, not an error.
        err == Libc.ENOENT && return nothing
        if err == Libc.ENOSPC
            throw(Base.IOError(
                "inotify watch limit reached while watching $(repr(dir)). " *
                "Raise it with: sysctl fs.inotify.max_user_watches=524288", -err))
        end
        throw(Base.IOError("inotify_add_watch($(repr(dir))) failed: $(Libc.strerror(err))", -err))
    end
    w.wd_to_dir[wd] = dir
    w.dir_to_wd[dir] = wd
    return nothing
end

# Watch every non-ignored directory below `dir`. When `out` is a vector,
# also synthesize Created events for entries found along the way (used when a
# directory appears after the watch started: its contents may predate our
# watch on it — the classic inotify race).
function _watch_tree!(w::InotifyBackend, dir::String, out::Union{Nothing,Vector{Any}})
    entries = try
        readdir(dir)
    catch
        return nothing   # deleted/unreadable in the meantime
    end
    for name in entries
        full = joinpath(dir, name)
        _isignored(w.ignore, relpath(full, w.root)) && continue
        out === nothing || push!(out, Created(full))
        if isdir(full)
            haskey(w.dir_to_wd, full) || _add_watch!(w, full)
            _watch_tree!(w, full, out)
        end
    end
    return nothing
end

function _evict_watch!(w::InotifyBackend, wd::Cint)
    dir = pop!(w.wd_to_dir, wd, nothing)
    dir === nothing || pop!(w.dir_to_wd, dir, nothing)
    return nothing
end

_isbelow(path::String, dir::String) = path == dir || startswith(path, dir * "/")

# A watched dir was renamed within the tree: inotify watches follow inodes, so
# every watch below `from` is still live but our path bookkeeping is stale.
# Rewrite the prefixes.
function _rename_tree!(w::InotifyBackend, from::String, to::String)
    for (wd, dir) in collect(w.wd_to_dir)
        if _isbelow(dir, from)
            newdir = to * dir[ncodeunits(from)+1:end]
            w.wd_to_dir[wd] = newdir
            pop!(w.dir_to_wd, dir, nothing)
            w.dir_to_wd[newdir] = wd
        end
    end
    return nothing
end

# A watched dir was moved OUT of the tree: its watches are still live on the
# relocated inodes and would keep reporting events under stale paths. Drop them.
function _evict_tree!(w::InotifyBackend, from::String)
    for (wd, dir) in collect(w.wd_to_dir)
        if _isbelow(dir, from)
            ccall(:inotify_rm_watch, Cint, (Cint, Cint), w.fd, wd)
            _evict_watch!(w, wd)
        end
    end
    return nothing
end

# Queue overflow: events were lost, our dir registry may be stale. Re-scan the
# tree to pick up unwatched directories; the caller emits `Other` to tell the
# consumer to rescan whatever state it derives from events.
function _resync!(w::InotifyBackend)
    w.recursive && _watch_tree!(w, w.root, nothing)
    return nothing
end

# ─── event pump ──────────────────────────────────────────────────────────────

function _pump(w::InotifyBackend)
    buf = Vector{UInt8}(undef, 65536)
    try
        while !w.closed
            try
                wait(w.fdw)
            catch e
                (w.closed || e isa EOFError) && break
                rethrow()
            end
            w.closed && break
            _drain!(w, buf)
        end
    catch e
        w.closed || _offer!(w.channel, e)
    finally
        close(w.channel)
    end
    return nothing
end

struct RawInotifyEvent
    wd::Cint
    mask::UInt32
    cookie::UInt32
    name::String
end

function _drain!(w::InotifyBackend, buf::Vector{UInt8})
    raws = RawInotifyEvent[]
    while true
        n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), w.fd, buf, length(buf))
        if n > 0
            _parse_buffer!(raws, buf, Int(n))
        elseif n == 0
            break
        else
            err = Libc.errno()
            err == Libc.EAGAIN && break     # fully drained
            err == Libc.EINTR && continue
            w.closed && break               # fd closed under us during teardown
            throw(Base.IOError("inotify read failed: $(Libc.strerror(err))", -err))
        end
    end
    isempty(raws) || _dispatch!(w, raws)
    return nothing
end

function _parse_buffer!(raws::Vector{RawInotifyEvent}, buf::Vector{UInt8}, n::Int)
    i = 1
    while i + 15 <= n
        wd     = reinterpret(Int32,  view(buf, i:i+3))[1]
        mask   = reinterpret(UInt32, view(buf, i+4:i+7))[1]
        cookie = reinterpret(UInt32, view(buf, i+8:i+11))[1]
        len    = Int(reinterpret(UInt32, view(buf, i+12:i+15))[1])
        name = ""
        if len > 0
            first = i + 16
            last = min(first + len - 1, n)
            nul = findnext(==(0x00), buf, first)
            stop = (nul === nothing || nul > last) ? last : nul - 1
            name = String(buf[first:stop])
        end
        push!(raws, RawInotifyEvent(Cint(wd), mask, cookie, name))
        i += 16 + len
    end
    return nothing
end

function _dispatch!(w::InotifyBackend, raws::Vector{RawInotifyEvent})
    out = Any[]
    pending_from = Dict{UInt32,String}()   # rename cookie → old path

    for raw in raws
        if (raw.mask & IN_Q_OVERFLOW) != 0
            _resync!(w)
            push!(out, Other(w.root))
            continue
        end
        if (raw.mask & IN_IGNORED) != 0
            _evict_watch!(w, raw.wd)
            continue
        end
        # A dir's own deletion/move is also reported by its parent's watch
        # (as IN_DELETE/IN_MOVED_FROM with ISDIR) — emitting SELF events too
        # would double-report. They're in DIR_MASK only implicitly via kernel
        # defaults; drop them here.
        (raw.mask & (IN_DELETE_SELF | IN_MOVE_SELF)) != 0 && continue

        dir = get(w.wd_to_dir, raw.wd, nothing)
        dir === nothing && continue         # stale event for an evicted watch
        full = raw.name == "" ? dir : joinpath(dir, raw.name)
        isdir_ = (raw.mask & IN_ISDIR) != 0

        _isignored(w.ignore, relpath(full, w.root)) && continue

        if (raw.mask & IN_MOVED_FROM) != 0
            pending_from[raw.cookie] = full
        elseif (raw.mask & IN_MOVED_TO) != 0
            from = pop!(pending_from, raw.cookie, nothing)
            if from === nothing
                # moved in from outside the tree: brand-new content
                push!(out, Created(full))
                isdir_ && _on_new_dir!(w, full, out)
            else
                push!(out, Renamed(from, full))
                # renamed within the tree: watches came along, fix bookkeeping
                isdir_ && w.recursive && _rename_tree!(w, from, full)
            end
        elseif (raw.mask & IN_CREATE) != 0
            push!(out, Created(full))
            isdir_ && _on_new_dir!(w, full, out)
        elseif (raw.mask & IN_DELETE) != 0
            push!(out, Removed(full))
        elseif (raw.mask & (IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB)) != 0
            push!(out, Modified(full))
        end
    end

    # A MOVED_FROM whose pair never arrived (moved outside the tree) = removal.
    for from in values(pending_from)
        push!(out, Removed(from))
        w.recursive && _evict_tree!(w, from)
    end

    # Collapse bursts within the batch: modify+close_write produce identical
    # events, and the new-directory rescan can duplicate kernel IN_CREATEs
    # non-adjacently. _merge_batch dedupes per path (no RenameHints here —
    # inotify pairs renames by cookie above).
    for ev in _merge_batch(out)
        _offer!(w.channel, ev)
    end
    return nothing
end

function _on_new_dir!(w::InotifyBackend, dir::String, out::Vector{Any})
    w.recursive || return nothing
    haskey(w.dir_to_wd, dir) || _add_watch!(w, dir)
    # Entries may already exist inside before our watch landed (mkpath, mv of
    # a whole tree): scan, watch nested dirs, synthesize Created for contents.
    _watch_tree!(w, dir, out)
    return nothing
end
