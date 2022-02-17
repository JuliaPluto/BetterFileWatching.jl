@enum Action Modify Create Delete

@testset "Snapshots" begin

    @testset "write/get" begin
        tmp_dir = mktempdir()

        write_file(p, content) = write(joinpath(tmp_dir, p), content)
        delete_file(p) = rm(joinpath(tmp_dir, p))

        write_file("not_modified.txt", "sticky")
        write_file("already_existing.txt", "Hello")
        write_file("should_be_deleted.txt", "oh no")

        snapshot_file = joinpath(tmp_dir, "snapshot.txt")
        BetterFileWatching.write_snapshot(tmp_dir, snapshot_file)

        delete_file("should_be_deleted.txt")
        write_file("already_existing.txt", "modified")
        write_file("newly_created.txt", "hey!")

        events = BetterFileWatching.get_events_since(tmp_dir, snapshot_file)

        @test count(events) do event
            basename(event.path) == "should_be_deleted.txt" &&
                event.is_deleted &&
                !event.is_created
        end == 1

        @test count(events) do event
            basename(event.path) == "newly_created.txt" &&
                !event.is_deleted &&
                event.is_created
        end == 1

        @test count(events) do event
            basename(event.path) == "already_existing.txt" &&
                !event.is_deleted &&
                !event.is_created
        end == 1

        @test count(events) do event
            basename(event.path) == "not_modified.txt"
        end == 0
    end

    @testset "Errors" begin
        tmp_dir = mktempdir()
        @test_throws ErrorException BetterFileWatching.write_snapshot(tmp_dir, "")

        @test_throws ErrorException BetterFileWatching.write_snapshot(tmp_dir, joinpath(tmp_dir, "notafolder/mysnapshot.txt"))

        @test_throws ErrorException BetterFileWatching.write_snapshot("not_existing.folder", "")
    end
end
