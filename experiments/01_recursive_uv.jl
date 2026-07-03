# Experiment 1: Can we get RECURSIVE file watching from Julia's own libuv,
# just by passing the UV_FS_EVENT_RECURSIVE flag that FileWatching hardcodes to 0?
#
# This copies the FolderMonitor pattern from the FileWatching stdlib
# (share/julia/stdlib/v1.12/FileWatching/src/FileWatching.jl:253) but exposes `flags`.
#
# libuv docs: UV_FS_EVENT_RECURSIVE (=4) is supported on macOS (FSEvents) and
# Windows (ReadDirectoryChangesW with bWatchSubtree=TRUE). Not on Linux (inotify).
#
# Run: julia experiments/01_recursive_uv.jl

include(joinpath(@__DIR__, "RecursiveFolderMonitor.jl"))

# ─── test scenario ───────────────────────────────────────────────────────────

function run_scenario(; flags::Int32)
    root = mktempdir()
    mkpath(joinpath(root, "a", "b"))

    mon = RecursiveFolderMonitor(root; flags)
    collected = []
    collector = @async for ev in mon.channel
        push!(collected, ev)
    end
    sleep(1.0)  # FSEvents streams have startup latency

    # 1. file at top level
    write(joinpath(root, "top.txt"), "hello")
    sleep(0.5)
    # 2. file in existing nested dir
    write(joinpath(root, "a", "b", "nested.txt"), "hello")
    sleep(0.5)
    # 3. brand-new dir created AFTER watch started, then a file inside it
    mkpath(joinpath(root, "newdir"))
    sleep(0.5)
    write(joinpath(root, "newdir", "inside_new.txt"), "hello")
    sleep(0.5)
    # 4. delete a nested file
    rm(joinpath(root, "a", "b", "nested.txt"))
    sleep(1.5)

    close(mon)
    wait(collector)
    return root, collected
end

for flags in (Int32(0), UV_FS_EVENT_RECURSIVE)
    println("═"^70)
    println("flags = $flags  ($(flags == 0 ? "current stdlib behavior" : "UV_FS_EVENT_RECURSIVE"))")
    println("═"^70)
    root, events = run_scenario(; flags)
    for ev in events
        println("  ", repr(ev))
    end
    println("  → $(length(events)) events (watch root was $root)")
end
