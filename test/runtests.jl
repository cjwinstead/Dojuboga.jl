using Dojuboga, Test, Random

const P = Dojuboga

@testset "Dojuboga" begin
    @testset "dominoes & constraints" begin
        @test Domino(5, 2) == Domino(2, 5)
        @test length(full_set(6)) == 28
        @test allunique(full_set(6))
        @test satisfies(Constraint(SUM, 7), [3, 4])
        @test !satisfies(Constraint(LESS, 7), [3, 4])
        @test satisfies(Constraint(GREATER, 6), [3, 4])
        @test satisfies(Constraint(EQUAL), [2, 2, 2])
        @test !satisfies(Constraint(NOTEQUAL), [1, 2, 1])
        @test strength(Constraint(NONE), 3, 6) == 0
        @test strength(Constraint(SUM, 0), 1, 6) ≈ log2(7)
        @test strength(Constraint(EQUAL), 3, 6) ≈ 2log2(7)
        # every valid constraint really holds
        for vals in ([0], [3, 3], [1, 5, 2], [6, 6, 6, 6])
            @test all(c -> satisfies(c, vals), P.valid_constraints(vals, 6))
        end
        @test P.implies(Constraint(SUM, 3), Constraint(LESS, 5))
        @test !P.implies(Constraint(SUM, 3), Constraint(EQUAL))
    end

    @testset "shape growth & partition" begin
        rng = Xoshiro(7)
        for n in 3:14
            pairs = P.grow_tiling(rng, n, ceil(Int, sqrt(4n)), 2.0)
            cells = [c for p in pairs for c in p]
            @test length(pairs) == n
            @test allunique(cells)
            @test all(sum(abs.(a .- b)) == 1 for (a, b) in pairs)   # adjacent halves
            board = P.Board(cells)
            regions = P.partition_regions(rng, board, [1, 3, 3, 1])
            @test sort(vcat(regions...)) == collect(1:ncells(board))
            @test all(P.connected(board, r) for r in regions)
        end
    end

    @testset "solver" begin
        # 1×4 strip with two dominoes and pinned cells has exactly one solution
        board = P.Board([(1, 1), (1, 2), (1, 3), (1, 4)])
        doms = [Domino(1, 2), Domino(3, 4)]
        inst = Instance(board, doms, [[1], [2], [3], [4]],
                        [Constraint(SUM, 2), Constraint(SUM, 1), Constraint(SUM, 4), Constraint(SUM, 3)])
        sols, _ = solve(inst; limit = 10)
        @test sols == [[2, 1, 4, 3]]
        # with no constraints: tiling is forced but each domino can go left/right and flip
        inst2 = Instance(board, doms, [[1, 2, 3, 4]], [Constraint(NONE)])
        sols2, _ = solve(inst2; limit = 100)
        @test length(sols2) == 8          # 2 orders × 2 × 2 orientations
    end

    @testset "generated puzzles" begin
        for lvl in LEVELS, seed in 1:8
            p = generate(lvl; seed = seed)
            inst = p.inst
            @test check_values(inst, p.values)                       # reference solution valid
            @test is_unique(inst)                                    # unique pip grid
            @test allunique(inst.dominoes)                           # all dominoes different
            @test 2length(inst.dominoes) == ncells(inst.board)
            @test sort(vcat(inst.regions...)) == collect(1:ncells(inst.board))
            @test all(P.connected(inst.board, r) for r in inst.regions)
            @test p.rating.level == lvl                              # hits requested level
            # reference placements cover the board and match the values
            cov = vcat([[pl.c1, pl.c2] for pl in p.solution]...)
            @test sort(cov) == collect(1:ncells(inst.board))
            @test all(p.values[pl.c1] == inst.dominoes[pl.domino].a &&
                      p.values[pl.c2] == inst.dominoes[pl.domino].b for pl in p.solution)
        end
        # determinism
        @test generate(:hard; seed = 99).values == generate(:hard; seed = 99).values
    end

    @testset "front-end API" begin
        g = new_game(:medium; seed = 11)
        p = puzzle(g)
        events = GameEvent[]
        id = subscribe!((_, e) -> push!(events, e), g)
        @test level(g) == :medium && seed(g) == 11 && rating(g) == p.rating
        @test ndominoes(g) == length(dominoes(g)) && 2ndominoes(g) == ncells(g)
        @test all(cell_at(g, cell_coords(g, i)...) == i for i in 1:ncells(g))
        @test sort(vcat([region_cells(g, r) for r in 1:nregions(g)]...)) == 1:ncells(g)
        @test all(region_of(g, rule_cell(g, r)) == r for r in 1:nregions(g))
        cols = region_colors(g, 10)
        @test cols == region_colors(g, 10)                       # stable
        @test all((cols[r] == 0) == (rule_label(g, r) == "") for r in 1:nregions(g))
        @test tray(g) == 1:ndominoes(g) && held(g) == 0 && preview(g, 1) === nothing
        @test !place!(g, 1) && events[end].kind == :rejected && message(g) != ""
        # play the reference solution through the API
        for pl in p.solution
            @test hold!(g, pl.domino) && held(g) == pl.domino
            (r1, c1) = cell_coords(g, pl.c1); (r2, c2) = cell_coords(g, pl.c2)
            while direction(g) != (r2 - r1, c2 - c1); turn!(g); end
            pv = preview(g, pl.c1)
            @test pv.a == pl.c1 && pv.b == pl.c2 && pv.fits
            @test place!(g, pl.c1)
            @test location(g, pl.domino) == (a = pl.c1, b = pl.c2)
            @test pip_at(g, pl.c1) == dominoes(g)[pl.domino].a && domino_at(g, pl.c2) == pl.domino
        end
        @test is_solved(g) && !was_revealed(g) && all(==(:ok), region_states(g))
        @test events[end].kind == :solved
        @test count(e -> e.kind == :placed, events) == ndominoes(g)
        t = elapsed(g); sleep(0.05); @test elapsed(g) == t          # frozen once solved
        @test !hint!(g) && !hold_next!(g) && !remove!(g, 1)         # nothing moves after solving
        # act!: pick up, swap, remove
        @test clear!(g) && !is_solved(g) && isempty(filter(!isnothing, [location(g, d) for d in 1:ndominoes(g)]))
        pl = p.solution[1]
        hold!(g, pl.domino); while direction(g) != (cell_coords(g, pl.c2) .- cell_coords(g, pl.c1)); turn!(g); end
        @test act!(g, pl.c1) && domino_at(g, pl.c1) == pl.domino   # place
        @test act!(g, pl.c1) && held(g) == pl.domino && domino_at(g, pl.c1) == 0   # pick up (keeps orientation)
        @test place!(g, pl.c1)
        hold!(g, p.solution[2].domino)
        @test act!(g, pl.c2) || held(g) == pl.domino               # swap or place
        @test remove!(g, pl.c1) || domino_at(g, pl.c1) == 0
        @test release!(g) || held(g) == 0
        # a full board other than the unique answer is not solved:
        # play the solution but flip one non-double domino
        clear!(g)
        k = findfirst(pl -> dominoes(g)[pl.domino].a != dominoes(g)[pl.domino].b, p.solution)
        for (i, pl) in enumerate(p.solution)
            (a, b) = i == k ? (pl.c2, pl.c1) : (pl.c1, pl.c2)
            hold!(g, pl.domino)
            while direction(g) != (cell_coords(g, b) .- cell_coords(g, a)); turn!(g); end
            @test place!(g, a)
        end
        @test isempty(tray(g)) && !is_solved(g) && any(==(:bad), region_states(g))
        @test occursin("not satisfied", message(g))
        # hints & reveal
        for _ in 1:ndominoes(g); hint!(g); end
        @test is_solved(g)
        clear!(g); @test reveal!(g) && is_solved(g) && was_revealed(g)
        unsubscribe!(g, id); n = length(events); clear!(g); @test length(events) == n
        @test_throws ArgumentError new_game(:impossible)
    end

    @testset "terminal UI" begin
        T = Dojuboga.Terminal
        kb(str) = T.readkey(IOBuffer(str))
        @test kb("\e[A") == :up && kb("\e[D") == :left && kb("\e[Z") == :backtab
        @test kb("\e[3~") == :delete && kb("\e") == :esc && kb("\r") == :enter
        @test kb("\t") == :tab && kb("\x7f") == :backspace && kb("r") == 'r' && kb("") == :quit
        for (lvl, sd) in ((:easy, 1), (:hard, 2), (:expert, 3), (:expert, 8))
            for color in (true, false)
                v = T.View(new_game(lvl; seed = sd); color = color)
                g = v.game; p = puzzle(g)
                @test occursin("tray:", T.render(v))
                for pl in p.solution                     # solve with keystrokes only
                    while held(g) != pl.domino; T.handle!(v, :tab); end
                    while direction(g) != (cell_coords(g, pl.c2) .- cell_coords(g, pl.c1)); T.handle!(v, 'r'); end
                    n = 0
                    while v.cursor != cell_coords(g, pl.c1) && n < 60
                        (r, c) = v.cursor; (tr, tc) = cell_coords(g, pl.c1)
                        T.handle!(v, tr < r ? :up : tr > r ? :down : tc < c ? :left : :right); n += 1
                    end
                    @test v.cursor == cell_coords(g, pl.c1)
                    T.handle!(v, :enter)
                end
                @test is_solved(g) && occursin("Solved", T.render(v))
                @test T.handle!(v, 'q') == :quit && T.handle!(v, '3') == :new && v.level == :hard
            end
        end
    end
end
