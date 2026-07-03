# Experiment 4 (Linux only): cost of per-directory inotify watches on a big tree.
# Run (Linux): julia experiments/04_linux_stress.jl

src = read(joinpath(@__DIR__, "02_linux_inotify.jl"), String)
defs = src[1:findfirst("# ─── test scenario", src)[1]-1]
include_string(Main, defs, "inotify_defs")

root = mktempdir()
for i in 1:100, j in 1:50
    mkpath(joinpath(root, "d$i", "s$j"))
end

t = @elapsed w = InotifyWatcher(root)
println("watch setup for 5101 dirs: ", round(t * 1000, digits=1), " ms, watches registered: ", length(w.wd_to_dir))

# event latency through FDWatcher on the big tree
events = []
done = Ref(false)
task = @async while !done[]
    try
        wait(w.fdw)
    catch
        break
    end
    drain!(events, w)
end
sleep(0.2)
for trial in 1:5
    empty!(events)
    t2 = @elapsed begin
        write(joinpath(root, "d50", "s25", "x$trial.txt"), "hi")
        while isempty(events)
            sleep(0.001)
        end
    end
    println("event latency, trial $trial: ", round(t2 * 1000, digits=1), " ms → ", events[1])
end
done[] = true
close(w.fdw)
