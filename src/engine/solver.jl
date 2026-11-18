# ---------------------------------------------------------------------------
# Exact solver (counts distinct solutions) and shared candidate machinery
# ---------------------------------------------------------------------------

"A legal option: domino `d` on adjacent cells `c1 < c2` showing pips `v1`, `v2`."
struct Cand
    d::Int
    c1::Int
    c2::Int
    v1::Int
    v2::Int
end
key(c::Cand) = (c.d, c.c1, c.c2, c.v1)

function placement(inst::Instance, c::Cand)
    dom = inst.dominoes[c.d]
    c.v1 == dom.a ? Placement(c.d, c.c1, c.c2) : Placement(c.d, c.c2, c.c1)
end

function cand(inst::Instance, p::Placement)
    dom = inst.dominoes[p.domino]
    p.c1 < p.c2 ? Cand(p.domino, p.c1, p.c2, dom.a, dom.b) : Cand(p.domino, p.c2, p.c1, dom.b, dom.a)
end

mutable struct State
    vals::Vector{Int}     # -1 = empty
    used::Vector{Bool}
    nplaced::Int
end
State(inst::Instance) = State(fill(-1, ncells(inst.board)), fill(false, length(inst.dominoes)), 0)

function apply!(st::State, c::Cand)
    st.vals[c.c1] = c.v1; st.vals[c.c2] = c.v2
    st.used[c.d] = true; st.nplaced += 1
end
function undo!(st::State, c::Cand)
    st.vals[c.c1] = -1; st.vals[c.c2] = -1
    st.used[c.d] = false; st.nplaced -= 1
end

"Pip range of the dominoes not yet placed."
function pip_range(inst::Instance, st::State)
    lo = typemax(Int); hi = -1
    for (d, dom) in enumerate(inst.dominoes)
        st.used[d] && continue
        lo = min(lo, dom.a); hi = max(hi, dom.b)
    end
    hi < 0 ? (0, 0) : (lo, hi)
end

@inline function cand_ok(inst, st, c1, v1, c2, v2, lo, hi)
    st.vals[c1] = v1; st.vals[c2] = v2
    r1 = inst.region_of[c1]; r2 = inst.region_of[c2]
    ok = region_feasible(inst, st.vals, r1, lo, hi) &&
         (r2 == r1 || region_feasible(inst, st.vals, r2, lo, hi))
    st.vals[c1] = -1; st.vals[c2] = -1
    ok
end

"""
    candidates(inst, st; banned)

Every placement of an unused domino on two empty adjacent cells that leaves
both touched regions feasible. `banned` holds keys removed by lookahead.
"""
function candidates(inst::Instance, st::State; banned = nothing)
    lo, hi = pip_range(inst, st)
    out = Cand[]
    for c1 in 1:ncells(inst.board)
        st.vals[c1] >= 0 && continue
        for c2 in inst.board.nbrs[c1]
            (c2 < c1 || st.vals[c2] >= 0) && continue
            for (d, dom) in enumerate(inst.dominoes)
                st.used[d] && continue
                if cand_ok(inst, st, c1, dom.a, c2, dom.b, lo, hi)
                    cd = Cand(d, c1, c2, dom.a, dom.b)
                    (banned === nothing || key(cd) ∉ banned) && push!(out, cd)
                end
                if dom.a != dom.b && cand_ok(inst, st, c1, dom.b, c2, dom.a, lo, hi)
                    cd = Cand(d, c1, c2, dom.b, dom.a)
                    (banned === nothing || key(cd) ∉ banned) && push!(out, cd)
                end
            end
        end
    end
    out
end

"Number of candidates touching each cell and using each domino."
function tally(inst::Instance, cands)
    cc = zeros(Int, ncells(inst.board)); dc = zeros(Int, length(inst.dominoes))
    for c in cands
        cc[c.c1] += 1; cc[c.c2] += 1; dc[c.d] += 1
    end
    cc, dc
end

"True if some empty cell or unused domino has no remaining option."
function dead(st::State, cc, dc)
    any(i -> st.vals[i] < 0 && cc[i] == 0, eachindex(cc)) ||
        any(d -> !st.used[d] && dc[d] == 0, eachindex(dc))
end

mutable struct SearchStats
    nodes::Int
    limit_hit::Bool
end

"""
    solve(inst; limit=2, node_limit=500_000) -> (solutions, stats)

Exhaustive search with minimum-remaining-values branching (on the most
constrained cell *or* domino). Solutions are distinct cell-value vectors, so
re-tilings that show identical pips and rotated doubles count once.
Stops after `limit` distinct solutions or `node_limit` nodes.
"""
function solve(inst::Instance; limit::Int = 2, node_limit::Int = 500_000)
    st = State(inst)
    seen = Set{Vector{Int}}(); out = Vector{Vector{Int}}()
    stats = SearchStats(0, false)
    _search!(inst, st, seen, out, limit, node_limit, stats)
    out, stats
end

function _search!(inst, st, seen, out, limit, node_limit, stats)
    stats.nodes += 1
    if stats.nodes > node_limit
        stats.limit_hit = true
        return true
    end
    if st.nplaced == length(inst.dominoes)
        if st.vals ∉ seen
            v = copy(st.vals); push!(seen, v); push!(out, v)
        end
        return length(out) >= limit
    end
    cands = candidates(inst, st)
    cc, dc = tally(inst, cands)
    best = typemax(Int); bcell = 0; bdom = 0
    for i in eachindex(cc)
        st.vals[i] >= 0 && continue
        cc[i] == 0 && return false
        if cc[i] < best
            best = cc[i]; bcell = i; bdom = 0
        end
    end
    for d in eachindex(dc)
        st.used[d] && continue
        dc[d] == 0 && return false
        if dc[d] < best
            best = dc[d]; bdom = d; bcell = 0
        end
    end
    for c in cands
        (bdom != 0 ? c.d == bdom : (c.c1 == bcell || c.c2 == bcell)) || continue
        apply!(st, c)
        stop = _search!(inst, st, seen, out, limit, node_limit, stats)
        undo!(st, c)
        stop && return true
    end
    false
end

"`true` iff the instance has exactly one distinct solution (and the search finished)."
function is_unique(inst::Instance; node_limit::Int = 500_000)
    sols, stats = solve(inst; limit = 2, node_limit = node_limit)
    length(sols) == 1 && !stats.limit_hit
end
