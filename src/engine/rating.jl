# ---------------------------------------------------------------------------
# Difficulty rating: a human-style logical solver
# ---------------------------------------------------------------------------
#
# Techniques, in the order they are tried (cheapest first):
#   T1  forced cell    – an empty cell has exactly one legal option       cost 1
#   T2  forced domino  – an unused domino has exactly one legal option    cost 2
#   T3  lookahead      – tentatively place an option, propagate T1/T2;
#                        if that leads to a contradiction, eliminate it   cost 6 per round + 1 per elimination
#   T4  guess          – nothing else works: commit to the reference
#                        solution's option on the most constrained cell   cost 12 * log2(#options)
#
# score = sum of costs; level = technique ceiling + score bands (see `classify`).

const COST_T1 = 1.0
const COST_T2 = 2.0
const COST_T3_ROUND = 6.0
const COST_T3_ELIM = 1.0
const COST_T4 = 12.0

"Apply T1/T2 to a fixpoint. Returns `(status, applied)` with status `:ok`, `:dead` or `:solved`."
function propagate!(inst, st, banned)
    applied = Cand[]
    while true
        st.nplaced == length(inst.dominoes) && return :solved, applied
        cands = candidates(inst, st; banned = banned)
        cc, dc = tally(inst, cands)
        dead(st, cc, dc) && return :dead, applied
        f = forced(st, cands, cc, dc)
        f === nothing && return :ok, applied
        apply!(st, f[1]); push!(applied, f[1])
    end
end

"First T1 move, else first T2 move, else `nothing`. Returns `(cand, technique)`."
function forced(st, cands, cc, dc)
    for i in eachindex(cc)
        if st.vals[i] < 0 && cc[i] == 1
            for c in cands
                (c.c1 == i || c.c2 == i) && return (c, 1)
            end
        end
    end
    for d in eachindex(dc)
        if !st.used[d] && dc[d] == 1
            for c in cands
                c.d == d && return (c, 2)
            end
        end
    end
    nothing
end

"""
    rate(inst, solution; lookahead_max=4)

Solve `inst` with techniques T1–T4 and return a [`Rating`](@ref).
T3 is only attempted on options of cells/dominoes with at most
`lookahead_max` remaining options (a human-plausible "try each case").
"""
function rate(inst::Instance, solution::Vector{Placement}; lookahead_max::Int = 4)
    st = State(inst)
    banned = Set{NTuple{4,Int}}()
    truth = Set(key(cand(inst, p)) for p in solution)
    singles = hidden = rounds = elims = guesses = 0
    t3cell = t3cell2 = t4cell = 0
    score = 0.0
    c0 = candidates(inst, st)
    cc0, _ = tally(inst, c0)
    branching = sum(cc0) / length(cc0)

    while st.nplaced < length(inst.dominoes)
        cands = candidates(inst, st; banned = banned)
        cc, dc = tally(inst, cands)
        dead(st, cc, dc) && error("rater reached a contradiction; puzzle inconsistent")
        f = forced(st, cands, cc, dc)
        if f !== nothing
            apply!(st, f[1])
            if f[2] == 1
                singles += 1; score += COST_T1
            else
                hidden += 1; score += COST_T2
            end
            continue
        end
        # most constrained empty cell (reported for the generator's assist step)
        best = typemax(Int); bcell = 0
        for i in eachindex(cc)
            if st.vals[i] < 0 && cc[i] < best
                best = cc[i]; bcell = i
            end
        end
        # T3: one-level lookahead with T1/T2 propagation
        n_el = 0
        for c in cands
            small = min(cc[c.c1], cc[c.c2], dc[c.d]) <= lookahead_max
            small || continue
            apply!(st, c)
            status, applied = propagate!(inst, st, banned)
            for a in Iterators.reverse(applied)
                undo!(st, a)
            end
            undo!(st, c)
            if status == :dead
                key(c) ∈ truth && error("lookahead eliminated the true solution")
                push!(banned, key(c)); n_el += 1
            end
        end
        if n_el > 0
            rounds == 0 && (t3cell = bcell)
            rounds == 1 && (t3cell2 = bcell)
            rounds += 1; elims += n_el
            score += COST_T3_ROUND + COST_T3_ELIM * n_el
            continue
        end
        # T4: guess (follow the reference solution at the most constrained cell)
        guesses == 0 && (t4cell = bcell)
        rounds == 0 && t3cell == 0 && (t3cell = bcell)
        idx = findfirst(c -> (c.c1 == bcell || c.c2 == bcell) && key(c) ∈ truth, cands)
        idx === nothing && error("reference solution not among candidates")
        apply!(st, cands[idx])
        guesses += 1; score += COST_T4 * log2(max(best, 2))
    end
    Rating(score, classify(score, rounds, guesses), singles, hidden, rounds, elims, guesses, branching,
           t3cell, t3cell2, t4cell)
end

const LEVELS = (:easy, :medium, :hard, :expert)
levelindex(l::Symbol) = findfirst(==(l), LEVELS)

"The cell where the rater first needed a technique above `target`'s ceiling (0 if none)."
function stuck_cell(r::Rating, target::Symbol)
    target == :easy   && return r.t3cell != 0 ? r.t3cell : r.t4cell
    target == :medium && return r.t4cell != 0 ? r.t4cell : r.t3cell2
    target == :hard   && return r.t4cell
    0
end

"""
    classify(score, lookahead_rounds, guesses)

Technique ceiling first, score second:
* `:easy`   – T1/T2 only and score < 22
* `:medium` – T1/T2 only (score ≥ 22), or at most one T3 round
* `:hard`   – two or more T3 rounds, no guessing
* `:expert` – at least one guess (T4) required
"""
function classify(score, rounds, guesses)
    guesses > 0 && return :expert
    rounds >= 2 && return :hard
    rounds == 1 && return :medium
    score < 22 ? :easy : :medium
end
