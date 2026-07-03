# The original BetterFileWatching ≤ 0.1 test suite, kept close to verbatim to
# guarantee that the rewrite stays a drop-in replacement: the callback API and
# the legacy blocking call. (Teardown is updated: stopping via
# InterruptException is replaced by cancellation tokens / a stop flag.)

using BetterFileWatching
using CancellationTokens

using Test

function poll(query::Function, timeout::Real=Inf64, interval::Real=1/20)
    start = time()
    while time() < start + timeout
        if query()
            return true
        end
        sleep(interval)
    end
    return false
end

"Like @async except it prints errors to the terminal. 👶"
macro asynclog(expr)
	quote
		@async begin
			# because this is being run asynchronously, we need to catch exceptions manually
			try
				$(esc(expr))
			catch ex
				bt = stacktrace(catch_backtrace())
				showerror(stderr, ex, bt)
				rethrow(ex)
			end
		end
	end
end



@testset "Basic - $(method)" for method in ["new", "legacy"]
    test_dir = tempname(cleanup=false)
    mkpath(test_dir)

    j(args...) = joinpath(test_dir, args...)


    write(j("script.jl"), "nice(123)")

    mkdir(j("mapje"))
    write(j("mapje", "cool.txt"), "hello")



    events = []
    last_length = Ref(0)

    stop_src = CancellationTokenSource()
    running = Ref(true)

    watch_task = if method == "new"
        @asynclog watch_folder(test_dir, get_token(stop_src)) do e
            @info "Event" e
            push!(events, e)
        end
    else
        @asynclog while running[]
            e = watch_folder(test_dir)
            @info "Event" e
            push!(events, e)
        end
    end

    sleep(2)

    @test length(events) == 0



    function somethingdetected()
        result = poll(10, 1/100) do
            length(events) > last_length[]
        end
        sleep(.5)
        last_length[] = length(events)
        result
    end



    write(j("mapje", "cool2.txt"), "hello")
    @test somethingdetected()

    write(j("mapje", "cool2.txt"), "hello again!")
    @test somethingdetected()

    write(j("asdf.txt"), "")
    @test somethingdetected()

    mv(j("mapje", "cool2.txt"), j("mapje", "cool3.txt"))
    @test somethingdetected()

    rm(j("mapje", "cool3.txt"))
    @test somethingdetected()


    sleep(2)

    # stop watching the folder
    if method == "new"
        cancel(stop_src)
    else
        running[] = false
        # the blocking call returns on the next event: keep poking until the
        # task notices (a write can land while the watcher is restarting)
        poll(15) do
            write(j("stop.txt"), "stop")
            istaskdone(watch_task)
        end
    end

    @test poll(() -> istaskdone(watch_task), 15)
    @test !istaskfailed(watch_task)
end
