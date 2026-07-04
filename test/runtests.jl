using Test
using BetterFileWatching
using BetterFileWatching: _merge_batch, RenameHint, _event_involves, _offer!,
    _isbelow, _parse_buffer!, RawInotifyEvent,
    IN_CREATE, IN_MODIFY, IN_MOVED_TO, IN_Q_OVERFLOW, IN_IGNORED, IN_DELETE_SELF
using CancellationTokens

# FSEvents streams take a moment to become active; ops right after
# watch-start can be missed on macOS. Elsewhere activation is immediate-ish.
const STARTUP = Sys.isapple() ? 2.5 : 0.5

"Poll `pred` until it's true or `timeout` elapses."
function await(pred::Function; timeout::Real = 20.0)
    t0 = time()
    while time() - t0 < timeout
        pred() && return true
        sleep(0.05)
    end
    return pred()
end

"Start watch_folder on `dir` in a task; hand `body` a snapshot getter; clean up."
function with_watcher(body::Function, dir::AbstractString; kwargs...)
    events = FileEvent[]
    lk = ReentrantLock()
    src = CancellationTokenSource()
    task = @async watch_folder(dir, get_token(src); kwargs...) do e
        lock(() -> push!(events, e), lk)
    end
    sleep(STARTUP)
    try
        body(() -> lock(() -> copy(events), lk))
    finally
        cancel(src)
        wait(task)   # rethrows if the watcher errored
    end
end

involves(ev::FileEvent, p) = p in paths_tuple(ev)
haspath(events, p) = any(ev -> involves(ev, p), events)
haspath(events, p, T::Type) = any(ev -> ev isa T && involves(ev, p), events)

newroot() = realpath(mktempdir())

@testset "BetterFileWatching" begin

    @testset "paths_tuple" begin
        @test paths_tuple(Created("/r/a")) == ("/r/a",)
        @test paths_tuple(Modified("/r/a")) == ("/r/a",)
        @test paths_tuple(Removed("/r/a")) == ("/r/a",)
        @test paths_tuple(Other("/r")) == ("/r",)
        @test paths_tuple(Renamed("/r/a", "/r/b")) == ("/r/a", "/r/b")
    end

    @testset "event equality, hashing, involvement (unit)" begin
        a, b, c = "/r/a", "/r/b", "/r/c"

        @test Created(a) == Created(a)
        @test Created(a) != Created(b)
        @test Created(a) != Modified(a)          # kind matters
        @test Renamed(a, b) == Renamed(a, b)
        @test Renamed(a, b) != Renamed(b, a)     # direction matters

        # hash is consistent with == (so events work in Sets/Dicts)
        @test hash(Created(a)) == hash(Created(a))
        @test hash(Created(a)) != hash(Modified(a))
        @test hash(Renamed(a, b)) == hash(Renamed(a, b))
        @test length(Set([Created(a), Created(a), Modified(a), Renamed(a, b)])) == 3

        @test _event_involves(Created(a), a)
        @test !_event_involves(Created(a), b)
        @test _event_involves(Renamed(a, b), a)
        @test _event_involves(Renamed(a, b), b)
        @test !_event_involves(Renamed(a, b), c)
    end

    @testset "_offer! never throws (unit)" begin
        ch = Channel{Any}(1)
        _offer!(ch, Created("/x"))
        @test take!(ch) == Created("/x")
        close(ch)
        @test _offer!(ch, Created("/y")) === nothing   # closed channel: swallowed
    end

    @testset "_isbelow (unit)" begin
        @test _isbelow("/a", "/a")
        @test _isbelow("/a/b", "/a")
        @test !_isbelow("/ab", "/a")     # sibling with shared prefix
        @test !_isbelow("/a", "/a/b")
    end

    @testset "inotify buffer parsing (unit)" begin
        # Craft raw `struct inotify_event` buffers (host-endian, like the
        # kernel hands them to `read`): int32 wd, uint32 mask, cookie, len,
        # then `len` name bytes (NUL-padded).
        function event_bytes(wd, mask, cookie, name; len = ncodeunits(name) == 0 ? 0 : ncodeunits(name) + 1)
            io = IOBuffer()
            write(io, Int32(wd), UInt32(mask), UInt32(cookie), UInt32(len))
            padded = zeros(UInt8, len)
            copyto!(padded, codeunits(name))
            write(io, padded)
            take!(io)
        end

        # several events in one read, with and without names, extra NUL padding
        buf = vcat(
            event_bytes(1, IN_CREATE, 0, "file.txt"; len = 16),  # padded like the kernel does
            event_bytes(2, IN_MODIFY, 0, ""),                    # dir-level event: no name
            event_bytes(3, IN_MOVED_TO, 42, "b"),
        )
        raws = RawInotifyEvent[]
        _parse_buffer!(raws, buf, length(buf))
        @test length(raws) == 3
        @test (raws[1].wd, raws[1].mask, raws[1].name) == (1, IN_CREATE, "file.txt")
        @test (raws[2].wd, raws[2].mask, raws[2].name) == (2, IN_MODIFY, "")
        @test (raws[3].cookie, raws[3].name) == (42, "b")
    end

    @testset "batch merging (unit)" begin
        a, b = "/r/a", "/r/b"

        # exact duplicates are suppressed, even when not adjacent
        @test _merge_batch(Any[Created(a), Created(b), Created(a)]) ==
              [Created(a), Created(b)]

        # ...but a genuine create → remove → create survives
        @test _merge_batch(Any[Created(a), Removed(a), Created(a)]) ==
              [Created(a), Removed(a), Created(a)]

        # adjacent rename hints (gone, then present) pair into Renamed
        @test _merge_batch(Any[RenameHint(a, false), RenameHint(b, true)]) ==
              [Renamed(a, b)]

        # unpaired hints degrade by existence
        @test _merge_batch(Any[RenameHint(a, true)]) == [Created(a)]
        @test _merge_batch(Any[RenameHint(a, false)]) == [Removed(a)]

        # same-path disappear + reappear is not a rename
        @test _merge_batch(Any[RenameHint(a, false), RenameHint(a, true)]) ==
              [Removed(a), Created(a)]

        # wrong order (present, then gone) does not pair
        @test _merge_batch(Any[RenameHint(a, true), RenameHint(b, false)]) ==
              [Created(a), Removed(b)]

        # a Modified between hints breaks adjacency — no false pair
        @test _merge_batch(Any[RenameHint(a, false), Modified(b), RenameHint(b, true)]) ==
              [Removed(a), Modified(b), Created(b)]
    end

    @testset "recursive watching" begin
        root = newroot()
        mkpath(joinpath(root, "a", "b"))

        with_watcher(root) do get_events
            # top-level file
            f_top = joinpath(root, "top.txt")
            write(f_top, "hello")
            @test await(() -> haspath(get_events(), f_top))

            # file in a pre-existing nested dir
            f_nested = joinpath(root, "a", "b", "nested.txt")
            write(f_nested, "hello")
            @test await(() -> haspath(get_events(), f_nested))

            # file in a directory tree created AFTER the watch started
            mkpath(joinpath(root, "new", "sub"))
            f_deep = joinpath(root, "new", "sub", "deep.txt")
            # give the backend a beat to register the new dirs (Linux race window)
            sleep(0.3)
            write(f_deep, "hello")
            @test await(() -> haspath(get_events(), f_deep))

            # deletion
            rm(f_nested)
            @test await(() -> haspath(get_events(), f_nested, Removed))
        end
    end

    @testset "event kinds (precise platforms)" begin
        # macOS: FSEvents flags are collapsed by libuv, kinds are best-effort.
        if !Sys.isapple()
            root = newroot()
            f = joinpath(root, "file.txt")
            write(f, "initial")

            with_watcher(root) do get_events
                open(io -> write(io, "more"), f, "a")
                @test await(() -> haspath(get_events(), f, Modified))

                g = joinpath(root, "created.txt")
                write(g, "x")
                @test await(() -> haspath(get_events(), g, Created))
            end
        end
    end

    @testset "rename within tree (Linux pairing)" begin
        root = newroot()
        f_old = joinpath(root, "old.txt")
        f_new = joinpath(root, "new.txt")
        write(f_old, "x")

        with_watcher(root) do get_events
            mv(f_old, f_new)
            if Sys.islinux()
                @test await(() -> any(ev -> ev isa Renamed && paths_tuple(ev) == (f_old, f_new), get_events()))
            else
                # coarse platforms: at least both paths show up
                @test await(() -> haspath(get_events(), f_new))
            end
        end
    end

    @testset "renamed directory keeps working (Linux bookkeeping)" begin
        root = newroot()
        mkpath(joinpath(root, "dir1"))

        with_watcher(root) do get_events
            mv(joinpath(root, "dir1"), joinpath(root, "dir2"))
            sleep(0.3)
            f = joinpath(root, "dir2", "after_rename.txt")
            write(f, "x")
            @test await(() -> haspath(get_events(), f))
        end
    end

    @testset "directory moved out of the tree" begin
        root = newroot()
        outside = newroot()
        mkpath(joinpath(root, "gone", "sub"))
        write(joinpath(root, "gone", "sub", "f.txt"), "x")

        with_watcher(root) do get_events
            mv(joinpath(root, "gone"), joinpath(outside, "gone"))
            @test await(() -> haspath(get_events(), joinpath(root, "gone")))
            if Sys.islinux()
                # an unpaired MOVED_FROM must degrade to Removed
                @test haspath(get_events(), joinpath(root, "gone"), Removed)
            end

            # the relocated tree must no longer report events (on Linux its
            # inode-following watches must be evicted)
            write(joinpath(outside, "gone", "sub", "late.txt"), "x")
            sleep(1.0)  # grace period for the stale event to (not) arrive
            @test !haspath(get_events(), joinpath(outside, "gone", "sub", "late.txt"))
        end
    end

    @testset "directory moved into the tree" begin
        root = newroot()
        outside = newroot()
        mkpath(joinpath(outside, "pkg", "sub"))
        write(joinpath(outside, "pkg", "sub", "inner.txt"), "x")

        with_watcher(root) do get_events
            mv(joinpath(outside, "pkg"), joinpath(root, "pkg"))
            @test await(() -> haspath(get_events(), joinpath(root, "pkg")))
            if Sys.islinux()
                # contents that came along with the move are synthesized as Created
                @test await(() -> haspath(get_events(), joinpath(root, "pkg", "sub", "inner.txt"), Created))
            end

            # the moved-in tree is actually being watched now
            sleep(0.3)
            f = joinpath(root, "pkg", "sub", "new.txt")
            write(f, "x")
            @test await(() -> haspath(get_events(), f))
        end
    end

    @testset "backend errors on a vanished path" begin
        # the public API checks isdir first; the backend must still fail
        # cleanly (releasing what it acquired) if the path is gone by then
        bad = joinpath(newroot(), "nope")
        @test_throws Base.IOError BetterFileWatching.UVBackend(bad; recursive = false, ignore = nothing)
    end

    @testset "closing a backend twice is safe" begin
        root = newroot()
        backend = BetterFileWatching.Backend(root; recursive = true, ignore = nothing)
        close(backend)
        close(backend)   # idempotent
        @test !isopen(backend.channel)
    end

    @testset "legacy blocking watch_file" begin
        root = newroot()
        target = joinpath(root, "t.txt")
        write(target, "x")

        result = Ref{Any}(nothing)
        task = @async (result[] = watch_file(target))
        # the blocking call gives no ready signal; poke until it returns
        # (writes right after watch-start can be missed on macOS)
        @test await(; timeout = 30.0) do
            istaskdone(task) && return true
            write(target, "poke")
            false
        end
        wait(task)
        @test result[] isa FileEvent
        @test involves(result[], target)
    end

    @testset "atomic save (write tmp + rename over target)" begin
        root = newroot()
        target = joinpath(root, "doc.txt")
        write(target, "v1")

        with_watcher(root) do get_events
            tmp = joinpath(root, "doc.txt.tmp")
            write(tmp, "v2")
            mv(tmp, target; force = true)
            # the save must surface on the *target* path, whatever the kind
            @test await(() -> haspath(get_events(), target))
        end
    end

    @testset "latency = 0 dispatches immediately" begin
        root = newroot()
        with_watcher(root; latency = 0.0) do get_events
            f = joinpath(root, "quick.txt")
            write(f, "x")
            @test await(() -> haspath(get_events(), f))
        end
    end

    @testset "ignore predicate" begin
        root = newroot()
        mkpath(joinpath(root, "skipme"))
        f_ignored = joinpath(root, "skipme", "hidden.txt")
        f_seen = joinpath(root, "seen.txt")

        with_watcher(root; ignore = rel -> startswith(rel, "skipme")) do get_events
            write(f_ignored, "x")
            write(f_seen, "x")
            @test await(() -> haspath(get_events(), f_seen))
            sleep(1.0)  # grace period for the ignored event to (not) arrive
            @test !haspath(get_events(), f_ignored)
        end
    end

    @testset "ignore predicate can skip .git path segments" begin
        root = newroot()
        mkpath(joinpath(root, "project", ".git"))
        mkpath(joinpath(root, "project", "src"))
        f_ignored = joinpath(root, "project", ".git", "HEAD")
        f_seen = joinpath(root, "project", "src", "main.jl")

        with_watcher(root; ignore = rel -> ".git" in split(rel, "/")) do get_events
            write(f_ignored, "ref: refs/heads/main\n")
            write(f_seen, "module Main\nend\n")
            @test await(() -> haspath(get_events(), f_seen))
            sleep(1.0)  # grace period for the ignored event to (not) arrive
            @test !haspath(get_events(), f_ignored)
        end
    end

    @testset "watch_file" begin
        root = newroot()
        target = joinpath(root, "watched.txt")
        sibling = joinpath(root, "sibling.txt")
        write(target, "initial")

        events = FileEvent[]
        lk = ReentrantLock()
        src = CancellationTokenSource()
        task = @async watch_file(target, get_token(src)) do e
            lock(() -> push!(events, e), lk)
        end
        sleep(STARTUP)
        try
            write(sibling, "noise")
            open(io -> write(io, "more"), target, "a")
            @test await(() -> lock(() -> haspath(events, target), lk))
            sleep(0.5)
            snapshot = lock(() -> copy(events), lk)
            @test all(ev -> involves(ev, target), snapshot)
            @test !haspath(snapshot, sibling)
        finally
            cancel(src)
            wait(task)
        end
    end

    @testset "cancellation" begin
        root = newroot()
        src = CancellationTokenSource()
        task = @async watch_folder(_ -> nothing, root, get_token(src))
        sleep(STARTUP)
        @test !istaskdone(task)
        cancel(src)
        @test await(() -> istaskdone(task); timeout = 10.0)
        @test !istaskfailed(task)

        # no crash when events happen after cancellation
        write(joinpath(root, "late.txt"), "x")
        sleep(0.3)
    end

    @testset "callback errors propagate" begin
        root = newroot()
        task = @async watch_folder(_ -> error("boom"), root)
        sleep(STARTUP)
        write(joinpath(root, "trigger.txt"), "x")
        @test await(() -> istaskdone(task); timeout = 10.0)
        @test istaskfailed(task)
    end

    @testset "errors on missing directory" begin
        @test_throws ArgumentError watch_folder(_ -> nothing, joinpath(newroot(), "nope"))
    end

    if Sys.islinux()
        @testset "inotify dispatch edge cases (unit)" begin
            root = newroot()
            sub = joinpath(root, "sub")
            mkpath(sub)
            backend = BetterFileWatching.InotifyBackend(root; recursive = true, ignore = nothing)
            try
                # kernel queue overflow: resync and tell the consumer via Other
                BetterFileWatching._dispatch!(backend,
                    [RawInotifyEvent(Cint(-1), IN_Q_OVERFLOW, UInt32(0), "")])
                @test take!(backend.channel) == Other(root)

                # IN_IGNORED evicts the watch from the bookkeeping
                wd = backend.dir_to_wd[sub]
                BetterFileWatching._dispatch!(backend,
                    [RawInotifyEvent(wd, IN_IGNORED, UInt32(0), "")])
                @test !haskey(backend.wd_to_dir, wd)
                @test !haskey(backend.dir_to_wd, sub)

                # events for an evicted/unknown wd are dropped, not crashed on
                BetterFileWatching._dispatch!(backend,
                    [RawInotifyEvent(wd, IN_CREATE, UInt32(0), "x.txt")])
                @test !isready(backend.channel)

                # SELF events are skipped (the parent watch reports them)
                rootwd = backend.dir_to_wd[root]
                BetterFileWatching._dispatch!(backend,
                    [RawInotifyEvent(rootwd, IN_DELETE_SELF, UInt32(0), "")])
                @test !isready(backend.channel)

                # registering a watch on a vanished dir is normal churn, not an error
                missing_dir = joinpath(root, "missing")
                @test BetterFileWatching._add_watch!(backend, missing_dir) === nothing
                @test !haskey(backend.dir_to_wd, missing_dir)
            finally
                close(backend)
            end
        end

        @testset "many directories (Linux stress)" begin
            root = newroot()
            for i in 1:50, j in 1:20
                mkpath(joinpath(root, "d$i", "s$j"))
            end
            with_watcher(root) do get_events
                f = joinpath(root, "d25", "s10", "x.txt")
                write(f, "x")
                @test await(() -> haspath(get_events(), f))
            end
        end
    end
end

include("legacy.jl")
