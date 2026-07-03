# Backend for macOS and Windows: the libuv that ships inside Julia already
# wraps the right OS facility (FSEvents on macOS, ReadDirectoryChangesW with
# bWatchSubtree on Windows) — the FileWatching stdlib just never passes the
# UV_FS_EVENT_RECURSIVE flag. This is the stdlib's FolderMonitor
# (FileWatching.jl:253 in Julia 1.12) with the flag exposed and events mapped
# to `FileEvent`s.
#
# Relies on the same Base internals the stdlib itself uses.

using Base: iolock_begin, iolock_end, eventloop, associate_julia_struct, disassociate_julia_struct,
    uv_error, _UVError, preserve_handle, unpreserve_handle

const UV_RENAME = Int32(1)
const UV_CHANGE = Int32(2)
const UV_FS_EVENT_RECURSIVE = Int32(4)

# Defined before UVBackend so the @cfunction in the constructor can resolve it.
function _uv_fseventscb(handle::Ptr{Cvoid}, filename::Ptr{Int8}, events::Int32, status::Int32)
    data = ccall(:jl_uv_handle_data, Ptr{Cvoid}, (Ptr{Cvoid},), handle)
    data == C_NULL && return nothing
    t = unsafe_pointer_to_objref(data)
    if status != 0
        _offer!(t.channel, _UVError("BetterFileWatching (uv backend)", status))
        return nothing
    end
    fname = (filename == C_NULL) ? "" : unsafe_string(convert(Cstring, filename))
    _isignored(t.ignore, fname) && return nothing
    full = fname == "" ? t.root : joinpath(t.root, fname)
    # libuv only distinguishes "change" (contents) from "rename" (appeared /
    # disappeared / renamed). We sample existence here and let the batch merge
    # step pair rename hints into `Renamed` or degrade them to Created/Removed.
    event = (events & UV_CHANGE) != 0 ? Modified(full) : RenameHint(full, ispath(full))
    _offer!(t.channel, event)
    return nothing
end

mutable struct UVBackend
    @atomic handle::Ptr{Cvoid}
    const root::String
    const ignore::Union{Nothing,Function}
    const channel::Channel{Any}

    function UVBackend(root::String; recursive::Bool, ignore::Union{Nothing,Function})
        handle = Libc.malloc(Base._sizeof_uv_fs_event)
        this = new(handle, root, ignore, Channel{Any}(Inf))
        associate_julia_struct(handle, this)
        iolock_begin()
        err = ccall(:uv_fs_event_init, Cint, (Ptr{Cvoid}, Ptr{Cvoid}), eventloop(), handle)
        if err != 0
            Libc.free(handle)
            iolock_end()
            throw(_UVError("BetterFileWatching (uv init)", err))
        end
        preserve_handle(this)
        finalizer(_uvfinalize, this)
        flags = recursive ? UV_FS_EVENT_RECURSIVE : Int32(0)
        cb = @cfunction(_uv_fseventscb, Cvoid, (Ptr{Cvoid}, Ptr{Int8}, Int32, Int32))
        err = ccall(:uv_fs_event_start, Int32, (Ptr{Cvoid}, Ptr{Cvoid}, Cstring, Int32),
            handle, cb, root, flags)
        if err != 0
            # failed to start: release everything acquired above
            disassociate_julia_struct(handle)
            unpreserve_handle(this)
            @atomic this.handle = C_NULL
            ccall(:jl_close_uv, Cvoid, (Ptr{Cvoid},), handle)  # frees handle in uv close cb
            iolock_end()
            uv_error("BetterFileWatching (uv start)", err)
        end
        iolock_end()
        return this
    end
end

# uv handle teardown only — safe to run as a finalizer (no task operations)
function _uvfinalize(t::UVBackend)
    iolock_begin()
    handle = t.handle
    if handle != C_NULL
        @atomic t.handle = C_NULL
        disassociate_julia_struct(handle)
        ccall(:uv_fs_event_stop, Int32, (Ptr{Cvoid},), handle)
        ccall(:jl_close_uv, Cvoid, (Ptr{Cvoid},), handle)  # async close; frees handle in uv close cb
        unpreserve_handle(t)
    end
    iolock_end()
    return nothing
end

function Base.close(t::UVBackend)
    _uvfinalize(t)
    close(t.channel)
    return nothing
end
