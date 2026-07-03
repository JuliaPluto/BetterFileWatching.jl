# Experiment 2 (Linux only): recursive watching with raw inotify via ccall,
# integrated with Julia's event loop through FileWatching.FDWatcher.
#
# This is the bun/Deno-notify strategy: inotify is NOT recursive, so we add a
# watch per directory (walkdir at start + dynamically for newly created dirs).
# The inotify fd is readable when events are pending, so instead of a blocking
# read on a dedicated thread (bun's approach), we let libuv poll the fd via
# FDWatcher and do non-blocking reads from a normal Julia task. No threads needed.
#
# Run (Linux): julia experiments/02_linux_inotify.jl

using FileWatching: FDWatcher

# ─── inotify constants (linux/inotify.h) ─────────────────────────────────────
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
const IN_ISDIR       = 0x40000000 % UInt32
const IN_Q_OVERFLOW  = 0x00004000 % UInt32
const IN_IGNORED     = 0x00008000 % UInt32
const IN_ONLYDIR     = 0x01000000 % UInt32
const IN_EXCL_UNLINK = 0x04000000 % UInt32

const DIR_MASK = IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO |
                 IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR | IN_EXCL_UNLINK

inotify_init1(flags) = ccall(:inotify_init1, Cint, (Cint,), flags)
inotify_add_watch(fd, path, mask) =
    ccall(:inotify_add_watch, Cint, (Cint, Cstring, UInt32), fd, path, mask)

# ─── recursive watcher ───────────────────────────────────────────────────────

mutable struct InotifyWatcher
    fd::Cint
    fdw::FDWatcher
    wd_to_dir::Dict{Cint,String}
    root::String
end

function add_watch!(w::InotifyWatcher, dir::String)
    wd = inotify_add_watch(w.fd, dir, DIR_MASK)
    wd < 0 && (@warn "inotify_add_watch failed" dir errno=Libc.errno(); return)
    w.wd_to_dir[wd] = dir
end

function InotifyWatcher(root::String)
    fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
    fd < 0 && error("inotify_init1 failed: errno=$(Libc.errno())")
    fdw = FDWatcher(RawFD(fd), true, false)   # readable, not writable
    w = InotifyWatcher(fd, fdw, Dict{Cint,String}(), root)
    add_watch!(w, root)
    for (base, dirs, _files) in walkdir(root)
        for d in dirs
            add_watch!(w, joinpath(base, d))
        end
    end
    return w
end

# One parsed event: (path relative to root, human-readable ops)
function process_buffer!(events, w::InotifyWatcher, buf::Vector{UInt8}, n::Int)
    i = 1
    while i <= n
        wd     = reinterpret(Int32,  buf[i:i+3])[1]
        mask   = reinterpret(UInt32, buf[i+4:i+7])[1]
        len    = reinterpret(UInt32, buf[i+12:i+15])[1]
        name = ""
        if len > 0
            raw = buf[i+16 : i+16+Int(len)-1]
            nul = findfirst(==(0x00), raw)
            name = String(raw[1:(nul === nothing ? end : nul - 1)])
        end
        i += 16 + Int(len)

        dir = get(w.wd_to_dir, wd, nothing)
        dir === nothing && continue
        fullpath = name == "" ? dir : joinpath(dir, name)
        relpath_ = relpath(fullpath, w.root)

        ops = String[]
        (mask & IN_CREATE)      != 0 && push!(ops, "create")
        (mask & IN_MODIFY)      != 0 && push!(ops, "modify")
        (mask & IN_CLOSE_WRITE) != 0 && push!(ops, "close_write")
        (mask & IN_ATTRIB)      != 0 && push!(ops, "attrib")
        (mask & IN_DELETE)      != 0 && push!(ops, "delete")
        (mask & IN_DELETE_SELF) != 0 && push!(ops, "delete_self")
        (mask & IN_MOVED_FROM)  != 0 && push!(ops, "moved_from")
        (mask & IN_MOVED_TO)    != 0 && push!(ops, "moved_to")
        (mask & IN_MOVE_SELF)   != 0 && push!(ops, "move_self")
        (mask & IN_Q_OVERFLOW)  != 0 && push!(ops, "OVERFLOW")
        (mask & IN_IGNORED)     != 0 && push!(ops, "ignored")
        isempty(ops) && push!(ops, "mask=0x$(string(mask, base=16))")
        push!(events, (relpath_, ops, (mask & IN_ISDIR) != 0))

        # THE critical recursive bit: newly created/moved-in dir → watch it too.
        # Race: entries may already exist inside before our watch lands (e.g.
        # `mkpath("newdir/sub")`, or `mv` of a whole tree). So after adding the
        # watch, scan the dir: watch nested subdirs and synthesize create
        # events for everything already present.
        if (mask & IN_ISDIR) != 0 && (mask & (IN_CREATE | IN_MOVED_TO)) != 0
            add_watch!(w, fullpath)
            for (base, dirs, files) in walkdir(fullpath)
                for d in dirs
                    add_watch!(w, joinpath(base, d))
                    push!(events, (relpath(joinpath(base, d), w.root), ["create (synthesized)"], true))
                end
                for f in files
                    push!(events, (relpath(joinpath(base, f), w.root), ["create (synthesized)"], false))
                end
            end
        end
    end
end

function drain!(events, w::InotifyWatcher)
    buf = Vector{UInt8}(undef, 65536)
    while true
        n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), w.fd, buf, length(buf))
        if n > 0
            process_buffer!(events, w, buf, Int(n))
        else
            err = Libc.errno()
            (n < 0 && err == Libc.EAGAIN) && return   # drained
            n == 0 && return
            error("inotify read failed: errno=$err")
        end
    end
end

# ─── test scenario ───────────────────────────────────────────────────────────

function main()
    root = mktempdir()
    mkpath(joinpath(root, "a", "b"))
    w = InotifyWatcher(root)
    events = []

    done = Ref(false)
    watch_task = @async while !done[]
        try
            wait(w.fdw)         # libuv-integrated: yields the task, no OS thread burned
        catch e
            e isa EOFError && break
            done[] && break
            rethrow()
        end
        drain!(events, w)
    end

    sleep(0.3)
    write(joinpath(root, "top.txt"), "hello")                 # top-level create
    sleep(0.2)
    write(joinpath(root, "a", "b", "nested.txt"), "hello")    # nested create
    sleep(0.2)
    mkpath(joinpath(root, "newdir", "sub"))                   # new dirs after start
    sleep(0.2)
    write(joinpath(root, "newdir", "sub", "deep.txt"), "x")   # file in new nested dir
    sleep(0.2)
    open(joinpath(root, "top.txt"), "a") do io; write(io, "more"); end  # modify
    sleep(0.2)
    rm(joinpath(root, "a", "b", "nested.txt"))                # nested delete
    sleep(0.5)

    done[] = true
    close(w.fdw)
    ccall(:close, Cint, (Cint,), w.fd)
    try wait(watch_task) catch end

    println("collected $(length(events)) events:")
    for (path, ops, isdir_) in events
        println("  ", rpad(path, 28), " ", join(ops, "+"), isdir_ ? "  [dir]" : "")
    end
end

main()
