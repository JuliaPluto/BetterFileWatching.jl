# Shared: FolderMonitor clone from the FileWatching stdlib, with the libuv
# `flags` argument exposed instead of hardcoded to 0.
# UV_FS_EVENT_RECURSIVE works on macOS (FSEvents) and Windows (RDCW subtree).

using FileWatching: FileWatching, FileEvent
using Base: iolock_begin, iolock_end, eventloop, associate_julia_struct, disassociate_julia_struct,
    uv_error, _UVError, preserve_handle, unpreserve_handle

const UV_FS_EVENT_RECURSIVE = Int32(4)

# NB: defined before the struct's @cfunction reference resolves it.
function _uv_fseventscb(handle::Ptr{Cvoid}, filename::Ptr{Int8}, events::Int32, status::Int32)
    data = ccall(:jl_uv_handle_data, Ptr{Cvoid}, (Ptr{Cvoid},), handle)
    data == C_NULL && return nothing
    t = unsafe_pointer_to_objref(data)
    if status != 0
        put!(t.channel, _UVError("RecursiveFolderMonitor", status))
    else
        fname = (filename == C_NULL) ? "" : unsafe_string(convert(Cstring, filename))
        put!(t.channel, fname => FileEvent(events))
    end
    return nothing
end

mutable struct RecursiveFolderMonitor
    @atomic handle::Ptr{Cvoid}
    const channel::Channel{Any}
    function RecursiveFolderMonitor(folder::String; flags::Int32 = UV_FS_EVENT_RECURSIVE)
        handle = Libc.malloc(Base._sizeof_uv_fs_event)
        this = new(handle, Channel{Any}(Inf))
        associate_julia_struct(handle, this)
        iolock_begin()
        err = ccall(:uv_fs_event_init, Cint, (Ptr{Cvoid}, Ptr{Cvoid}), eventloop(), handle)
        if err != 0
            Libc.free(handle)
            iolock_end()
            throw(_UVError("RecursiveFolderMonitor", err))
        end
        preserve_handle(this)
        cb = @cfunction(_uv_fseventscb, Cvoid, (Ptr{Cvoid}, Ptr{Int8}, Int32, Int32))
        uv_error("RecursiveFolderMonitor (start)",
            ccall(:uv_fs_event_start, Int32, (Ptr{Cvoid}, Ptr{Cvoid}, Cstring, Int32),
                handle, cb, folder, flags))
        iolock_end()
        return this
    end
end

function Base.close(t::RecursiveFolderMonitor)
    iolock_begin()
    if t.handle != C_NULL
        ccall(:uv_fs_event_stop, Int32, (Ptr{Cvoid},), t.handle)
        ccall(:jl_close_uv, Cvoid, (Ptr{Cvoid},), t.handle)  # async close; frees handle in close_cb
        disassociate_julia_struct(t.handle)
        @atomic t.handle = C_NULL
        unpreserve_handle(t)
    end
    iolock_end()
    close(t.channel)
end
