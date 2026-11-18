# ---------------------------------------------------------------------------
# Puzzle generation (see SPEC.md for the full specification)
# ---------------------------------------------------------------------------

"""
    Profile

Generation knobs for one difficulty level.

* `ndominoes`      – range for the number of dominoes n (board has 2n cells)
* `maxpip`         – highest pip value (6 = double-six set)
* `compactness`    – shape growth bias; weight of a frontier cell = compactness^(k-1),
                     k = occupied neighbours (<1 stringy, 1 neutral, >1 blobby)
* `size_weights`   – relative weights for region sizes 1, 2, 3, …
* `kind_weights`   – relative weights of rule kinds when weakening (G7)
* `slack`          – mean extra slack for inequalities (geometric distribution)
* `tighten`        – `:strong` or `:weak`: which excluding rule move (a) of G5 prefers
* `loosen`         – fraction of regions offered a weaker rule in G7
* `merge_tries`    – maximum number of region merges (each kept only if still unique)
* `equal_affinity` – while growing a region whose pips are all equal so far, a
                     neighbour with the same pip gets weight × (1 + equal_affinity);
                     this seeds `=` regions
"""
Base.@kwdef struct Profile
    ndominoes::UnitRange{Int}
    maxpip::Int = 6
    compactness::Float64 = 3.0
    size_weights::Vector{Float64}
    kind_weights::Dict{ConstraintKind,Float64}
    slack::Float64 = 1.0
    tighten::Symbol = :strong
    loosen::Float64 = 0.0
    merge_tries::Int = 0
    equal_affinity::Float64 = 4.0
end

const PROFILES = Dict{Symbol,Profile}(
    :easy => Profile(ndominoes = 5:7, compactness = 3.0,
        size_weights = [0.5, 4, 3, 1],
        kind_weights = Dict(SUM => 5, EQUAL => 3, NOTEQUAL => 1, LESS => 1, GREATER => 1, NONE => 1),
        slack = 0.3, tighten = :strong, loosen = 1.0, merge_tries = 20),
    :medium => Profile(ndominoes = 7:9, compactness = 3.0,
        size_weights = [0.5, 4, 4, 2, 1],
        kind_weights = Dict(SUM => 4, EQUAL => 2, NOTEQUAL => 1.5, LESS => 1.5, GREATER => 1.5, NONE => 2),
        slack = 0.8, tighten = :weak, loosen = 1.0, merge_tries = 20),
    :hard => Profile(ndominoes = 9:11, compactness = 2.5,
        size_weights = [0.3, 3, 4, 3, 1.5],
        kind_weights = Dict(SUM => 3, EQUAL => 2, NOTEQUAL => 2, LESS => 2, GREATER => 2, NONE => 3),
        slack = 1.2, tighten = :weak, loosen = 1.0, merge_tries = 20),
    :expert => Profile(ndominoes = 11:13, compactness = 2.5,
        size_weights = [0.3, 2, 4, 4, 2, 1],
        kind_weights = Dict(SUM => 2, EQUAL => 2, NOTEQUAL => 2, LESS => 2, GREATER => 2, NONE => 3),
        slack = 1.5, tighten = :weak, loosen = 1.0, merge_tries = 20),
)

# --- small helpers ------------------------------------------------------------

"""
Acceptance test used by every weakening step: the instance must stay unique
and (when a target level is given) must not be rated above it.
"""
function acceptable(inst, solution, target; node_limit = 300_000)
    is_unique(inst; node_limit = node_limit) || return false
    target === nothing && return true
    levelindex(rate(inst, solution).level) <= levelindex(target)
end

function wsample(rng, items, weights)
    t = rand(rng) * sum(weights); acc = 0.0
    for (it, w) in zip(items, weights)
        acc += w
        acc >= t && return it
    end
    last(items)
end

geometric(rng, mean) = mean <= 0 ? 0 : floor(Int, log(rand(rng)) / log(mean / (1 + mean)))

nbr4((r, c)) = ((r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1))

# --- G1: shape + tiling ------------------------------------------------------

"""
    grow_tiling(rng, n, maxdim, compactness) -> Vector{Tuple{Coord,Coord}}

Grow a connected polyomino of 2n cells by adding one domino at a time, so the
shape is born together with a valid tiling. The bounding box never exceeds
`maxdim × maxdim`.
"""
function grow_tiling(rng, n::Int, maxdim::Int, compactness::Float64)
    while true
        occ = Set{Coord}(); pairs = Tuple{Coord,Coord}[]
        a = (0, 0); b = rand(rng, Bool) ? (0, 1) : (1, 0)
        push!(occ, a, b); push!(pairs, (a, b))
        fits(x) = begin
            rs = (min(minimum(first, occ), x[1]), max(maximum(first, occ), x[1]))
            cs = (min(minimum(last, occ), x[2]), max(maximum(last, occ), x[2]))
            rs[2] - rs[1] < maxdim && cs[2] - cs[1] < maxdim
        end
        weight(x) = compactness^(count(in(occ), nbr4(x)) - 1)
        stuck = false
        while length(pairs) < n
            frontier = unique!([y for x in occ for y in nbr4(x) if y ∉ occ && fits(y)])
            placed = false
            while !isempty(frontier)
                x = wsample(rng, frontier, weight.(frontier))
                partners = [y for y in nbr4(x) if y ∉ occ && fits(y)]
                if isempty(partners)
                    filter!(!=(x), frontier); continue
                end
                y = wsample(rng, partners, [1 + count(in(occ), nbr4(p)) for p in partners])
                push!(occ, x, y); push!(pairs, (x, y)); placed = true
                break
            end
            placed || (stuck = true; break)
        end
        stuck || return pairs
    end
end

# --- G3: regions -------------------------------------------------------------

"""
    partition_regions(rng, board, weights)

Partition the board into connected regions with target sizes drawn from
`weights` (index = size). Seeds and growth both favour the cells with the
fewest unassigned neighbours, so few cells get stranded; a stranded cell
(region smaller than its target, size 1) is absorbed by its smallest
neighbouring region.
"""
function partition_regions(rng, board::Board, weights; values = nothing, affinity = 0.0)
    n = ncells(board)
    owner = zeros(Int, n); regions = Vector{Int}[]; targets = Int[]
    free(x) = count(y -> owner[y] == 0, board.nbrs[x])
    while any(==(0), owner)
        un = shuffle!(rng, findall(==(0), owner))
        seed = un[argmin(free.(un))]
        target = wsample(rng, 1:length(weights), weights)
        id = length(regions) + 1
        reg = [seed]; owner[seed] = id
        while length(reg) < target
            fr = unique!([y for x in reg for y in board.nbrs[x] if owner[y] == 0])
            isempty(fr) && break
            alleq = values !== nothing && all(==(values[seed]), values[reg])
            y = wsample(rng, fr, [(1 + (alleq && values[f] == values[seed]) * affinity) / (1 + free(f))
                                  for f in fr])
            push!(reg, y); owner[y] = id
        end
        push!(regions, reg); push!(targets, target)
    end
    # absorb stranded singletons
    for (i, reg) in enumerate(regions)
        (length(reg) == 1 && targets[i] > 1) || continue
        x = reg[1]
        nb = unique([owner[y] for y in board.nbrs[x] if owner[y] != i && !isempty(regions[owner[y]])])
        isempty(nb) && continue
        j = nb[argmin([length(regions[k]) for k in nb])]
        push!(regions[j], x); owner[x] = j; empty!(reg)
    end
    [sort!(r) for r in regions if !isempty(r)]
end

# --- G4–G7: constraints -------------------------------------------------------

"""
    initial_constraint(rng, vals, prof)

Top-down start (SPEC G4): every region begins with its most informative rule,
an exact SUM — or `=` when all its pips are equal (probability ½).
"""
function initial_constraint(rng, vals, prof::Profile)
    length(vals) >= 2 && all(==(vals[1]), vals) && rand(rng) < 0.5 && return Constraint(EQUAL)
    Constraint(SUM, sum(vals))
end

"Constraints true for `vals` but false for `alt` (same region)."
function excluding(vals, alt, maxpip)
    filter(c -> !satisfies(c, alt), valid_constraints(vals, maxpip))
end

"Split cell `c` out of region `r` as a pinned singleton (exact value)."
pin!(regions, constraints, r, c, values, board) = carve!(regions, constraints, r, [c], values, board)

"""
Split the connected cell set `carved` out of region `r` as a new exact-SUM
region; the remainder is split into connected components that inherit a rule
derived from the old one.
"""
function carve!(regions, constraints, r, carved, values, board)
    rest = filter(∉(carved), regions[r]); old = constraints[r]; cv = sum(values[carved])
    # connected components of the remainder
    comps = Vector{Int}[]; left = Set(rest)
    while !isempty(left)
        s = first(left); comp = [s]; delete!(left, s); i = 1
        while i <= length(comp)
            for y in board.nbrs[comp[i]]
                y ∈ left && (push!(comp, y); delete!(left, y))
            end
            i += 1
        end
        push!(comps, sort!(comp))
    end
    newcons = Constraint[]
    for comp in comps
        v = values[comp]; s = sum(v)
        nc = if old.kind == NONE
            Constraint(NONE)
        elseif old.kind == EQUAL && length(comp) >= 2
            Constraint(EQUAL)
        elseif old.kind == NOTEQUAL && length(comp) >= 2
            Constraint(NOTEQUAL)
        elseif old.kind == LESS && length(comps) == 1
            Constraint(LESS, old.k - cv)        # equivalent to the old rule given the carved sum
        elseif old.kind == GREATER && length(comps) == 1
            Constraint(GREATER, max(old.k - cv, -1))
        else
            Constraint(SUM, s)
        end
        # a GREATER(-1) is vacuous
        nc.kind == GREATER && nc.k < 0 && (nc = Constraint(NONE))
        push!(newcons, nc)
    end
    regions[r] = sort(carved); constraints[r] = Constraint(SUM, cv)
    append!(regions, comps); append!(constraints, newcons)
    nothing
end


"Is the cell set connected (4-neighbourhood)?"
function connected(board::Board, cells)
    isempty(cells) && return false
    set = Set(cells); seen = Set([first(cells)]); stack = [first(cells)]
    while !isempty(stack)
        x = pop!(stack)
        for y in board.nbrs[x]
            (y ∈ set && y ∉ seen) && (push!(seen, y); push!(stack, y))
        end
    end
    length(seen) == length(set)
end

"""
Re-derive a rule of the same kind for a region whose cells changed: SUM gets
the new sum, inequalities keep their slack, `=`/`≠` are kept if still true
(else SUM), NONE stays NONE.
"""
function adapt(old::Constraint, vals, maxpip)
    n = length(vals); s = sum(vals)
    old.kind == NONE && return old
    old.kind == EQUAL && n >= 2 && all(==(vals[1]), vals) && return old
    old.kind == NOTEQUAL && n >= 2 && allunique(vals) && return old
    old.kind == LESS && s < n * maxpip && return Constraint(LESS, min(s + 1, n * maxpip))
    old.kind == GREATER && s > 0 && return Constraint(GREATER, s - 1)
    Constraint(SUM, s)
end

"""
Find a split of `cells` into two connected parts (each >= 2 cells) whose
adapted rules exclude the alternative solution `W`; prefer balanced splits.
"""
function bisect(rng, board, cells, old, values, W, m; avoid = nothing)
    n = length(cells); best = nothing; bestscore = -1.0
    n > 10 && return nothing
    for mask in 1:(1 << (n - 1)) - 1          # last cell always in B ⇒ each split once
        A = [cells[i] for i in 1:n if (mask >> (i - 1)) & 1 == 1]
        B = [cells[i] for i in 1:n if (mask >> (i - 1)) & 1 == 0]
        (length(A) >= 2 && length(B) >= 2) || continue
        avoid !== nothing && (Set(A) == avoid || Set(B) == avoid) && continue
        (connected(board, A) && connected(board, B)) || continue
        ca = adapt(old, values[A], m); cb = adapt(old, values[B], m)
        ca.kind == NONE && (ca = Constraint(SUM, sum(values[A])))
        cb.kind == NONE && (cb = Constraint(SUM, sum(values[B])))
        (satisfies(ca, W[A]) && satisfies(cb, W[B])) && continue
        sc = min(length(A), length(B)) + rand(rng)
        sc > bestscore && (best = ((A, ca), (B, cb)); bestscore = sc)
    end
    best
end

ispinned(regions, constraints, r) = length(regions[r]) == 1 && constraints[r].kind == SUM

"""
    make_unique!(rng, board, doms, regions, constraints, values, prof)

Tighten constraints until the instance has a single solution (SPEC G5).
Returns the final `Instance`.
"""
function make_unique!(rng, board, doms, regions, constraints, values, prof; node_limit = 300_000)
    m = prof.maxpip
    nonmono = 0; carves = 0; cap = length(regions)
    for _ in 1:10 * ncells(board)
        inst = Instance(board, doms, regions, constraints)
        sols, stats = solve(inst; limit = 2, node_limit = node_limit)
        length(sols) == 1 && !stats.limit_hit && return inst
        alt = findfirst(!=(values), sols)
        if alt === nothing
            # search budget exhausted: harden the weakest unpinned region to an exact sum
            rs = [r for r in eachindex(regions) if constraints[r].kind != SUM]
            isempty(rs) && (rs = [r for r in eachindex(regions) if !ispinned(regions, constraints, r)])
            r = argmin(r -> strength(constraints[r], length(regions[r]), m), rs)
            if constraints[r].kind == SUM
                pin!(regions, constraints, r, rand(rng, regions[r]), values, board)
            else
                constraints[r] = Constraint(SUM, sum(values[regions[r]]))
            end
            continue
        end
        W = sols[alt]
        diffcells = [c for c in eachindex(values) if values[c] != W[c]]
        diffregs = shuffle(rng, unique([inst.region_of[c] for c in diffcells]))
        moved = false
        # (a) monotone strengthening of one differing region
        for r in diffregs
            opts = filter(c -> implies(c, constraints[r]),
                          excluding(values[regions[r]], W[regions[r]], m))
            isempty(opts) && continue
            constraints[r] = prof.tighten == :strong ?
                argmax(c -> strength(c, length(regions[r]), m), opts) :
                argmin(c -> strength(c, length(regions[r]), m), opts)
            moved = true; break
        end
        # (b) bisect a differing region into two connected parts of >= 2 cells
        if !moved
            for r in diffregs
                length(regions[r]) >= 4 || continue
                ispinned(regions, constraints, r) && continue
                split = bisect(rng, board, regions[r], constraints[r], values, W, m)
                split === nothing && continue
                (A, ca), (B, cb) = split
                regions[r] = A; constraints[r] = ca
                push!(regions, B); push!(constraints, cb)
                moved = true; break
            end
        end
        # (c) non-monotone replacement by an excluding rule of >= information
        if !moved && nonmono < cap
            for r in diffregs
                s0 = strength(constraints[r], length(regions[r]), m)
                all_opts = filter(c -> c.kind != NONE, excluding(values[regions[r]], W[regions[r]], m))
                isempty(all_opts) && continue
                opts = filter(c -> strength(c, length(regions[r]), m) >= s0, all_opts)
                isempty(opts) && (opts = all_opts)
                constraints[r] = argmin(c -> strength(c, length(regions[r]), m), opts)
                nonmono += 1; moved = true; break
            end
        end
        # (d) carve a differing pair with a distinguishing sum (bounded number of times)
        if !moved && carves < ncells(board) ÷ 4
            for c in shuffle(rng, diffcells)
                r = inst.region_of[c]
                length(regions[r]) >= 4 || continue
                ys = [y for y in board.nbrs[c] if inst.region_of[y] == r &&
                      values[c] + values[y] != W[c] + W[y] &&
                      connected(board, filter(∉((c, y)), regions[r]))]
                isempty(ys) && continue
                carve!(regions, constraints, r, [c, rand(rng, ys)], values, board)
                carves += 1; moved = true; break
            end
        end
        # (e) pin a differing cell (always possible; guarantees termination)
        if !moved
            c = rand(rng, diffcells)
            pin!(regions, constraints, inst.region_of[c], c, values, board)
        end
    end
    error("make_unique! did not converge")
end

"""
    weaker_options(rng, vals, cur, prof)

Candidate replacements for a region's rule during weakening, in the order they
are tried: at most one per kind (`=`, `≠`, `<k`, `>k`, none), each strictly
less informative than `cur`; inequality thresholds sit `slack` (geometric)
above/below the true sum; the order is a weighted shuffle by `kind_weights`.
"""
function weaker_options(rng, vals, cur, prof)
    n = length(vals); s = sum(vals); m = prof.maxpip
    s0 = strength(cur, n, m)
    cands = Constraint[Constraint(NONE)]
    s < n * m && push!(cands, Constraint(LESS, min(s + 1 + geometric(rng, prof.slack), n * m)))
    s > 0 && push!(cands, Constraint(GREATER, max(s - 1 - geometric(rng, prof.slack), 0)))
    if n >= 2
        all(==(vals[1]), vals) && push!(cands, Constraint(EQUAL))
        allunique(vals) && push!(cands, Constraint(NOTEQUAL))
    end
    filter!(c -> strength(c, n, m) < s0 - 1e-9, cands)
    w = [get(prof.kind_weights, c.kind, 0.0) + 1e-9 for c in cands]
    cands[sortperm(-log.(rand(rng, length(cands))) ./ w)]   # weighted random order
end

"""
Weakening pass (SPEC G7): merge adjacent regions, then offer a fraction
(`prof.loosen`) of the regions a weaker rule. Every change is kept only if the
puzzle stays unique and is not rated above the target level.
"""
function loosen!(rng, board, doms, regions, constraints, values, prof;
                 solution = Placement[], target = nothing, node_limit = 300_000)
    m = prof.maxpip
    merge_regions!(rng, board, doms, regions, constraints, values, prof;
                   solution = solution, target = target, node_limit = node_limit)
    order = shuffle(rng, collect(eachindex(regions)))
    for r in order[1:round(Int, prof.loosen * length(order))]
        opts = weaker_options(rng, values[regions[r]], constraints[r], prof)
        cur = constraints[r]
        for c in opts
            constraints[r] = c
            acceptable(Instance(board, doms, regions, constraints), solution, target;
                       node_limit = node_limit) && break
            constraints[r] = cur
        end
    end
    Instance(board, doms, regions, constraints)
end

"""
    merge_regions!(rng, board, doms, regions, constraints, values, prof)

Try to merge pairs of adjacent constrained regions (smallest first) into one
region whose rule is the merged region's SUM (or `=`/`≠` when they hold and
the profile is not easy); a merge is kept only if the puzzle stays unique.
Reduces the number of tiny regions left over by pinning.
"""
function merge_regions!(rng, board, doms, regions, constraints, values, prof;
                        solution = Placement[], target = nothing, node_limit = 300_000)
    merges = 0
    while merges < prof.merge_tries
        adj = Tuple{Int,Int}[]
        for a in eachindex(regions), b in a+1:length(regions)
            constraints[a].kind == NONE && continue
            constraints[b].kind == NONE && continue
            length(regions[a]) + length(regions[b]) <= length(prof.size_weights) || continue
            any(y ∈ regions[b] for x in regions[a] for y in board.nbrs[x]) && push!(adj, (a, b))
        end
        # prefer merging small regions (singletons first)
        sort!(shuffle!(rng, adj); by = p -> min(length(regions[p[1]]), length(regions[p[2]])))
        merged = false
        for (a, b) in adj
            cells = sort!(vcat(regions[a], regions[b])); v = values[cells]
            opts = [Constraint(SUM, sum(v))]
            all(==(v[1]), v) && pushfirst!(opts, Constraint(EQUAL))
            allunique(v) && rand(rng) < 0.5 && pushfirst!(opts, Constraint(NOTEQUAL))
            for c in opts
                R2 = copy(regions); C2 = copy(constraints)
                R2[a] = cells; C2[a] = c
                deleteat!(R2, b); deleteat!(C2, b)
                if acceptable(Instance(board, doms, R2, C2), solution, target; node_limit = node_limit)
                    empty!(regions); append!(regions, R2)
                    empty!(constraints); append!(constraints, C2)
                    merged = true; break
                end
            end
            merged && break
        end
        merged || return
        merges += 1
    end
end

"""
    generate(difficulty=:medium; seed, maxattempts=30, profile) -> Puzzle

Generate a puzzle with a unique solution whose rated level matches
`difficulty` (one of `:easy, :medium, :hard, :expert`). If no attempt hits the
target, the closest one is returned. Same `seed` ⇒ same puzzle (for a given
Julia version).
"""
function generate(difficulty::Symbol = :medium; seed::Integer = rand(UInt64),
                  maxattempts::Int = 30, profile::Profile = PROFILES[difficulty])
    rng = Xoshiro(seed)
    target = findfirst(==(difficulty), LEVELS)
    best = nothing; bestd = Inf
    for _ in 1:maxattempts
        p = generate_once(rng, profile, difficulty, UInt64(seed))
        lv = findfirst(==(p.rating.level), LEVELS)
        d = abs(lv - target)
        d == 0 && return p
        if d < bestd
            best = p; bestd = d
        end
    end
    best
end

function generate_once(rng, prof::Profile, difficulty, seed)
    n = rand(rng, prof.ndominoes)
    maxdim = ceil(Int, sqrt(2n * 2.0))
    pairs = grow_tiling(rng, n, maxdim, prof.compactness)            # G1
    board = Board([c for p in pairs for c in p])
    # G2: choose n distinct dominoes, assign them to the tiling, orient them
    set = full_set(prof.maxpip)
    doms = sort(shuffle(rng, set)[1:n]; by = d -> (d.a, d.b))
    order = shuffle(rng, 1:n)
    values = fill(-1, ncells(board)); solution = Placement[]
    rmin = minimum(min(x[1], y[1]) for (x, y) in pairs)
    cmin = minimum(min(x[2], y[2]) for (x, y) in pairs)
    for (i, (x, y)) in enumerate(pairs)
        cx = board.index[(x[1] - rmin + 1, x[2] - cmin + 1)]
        cy = board.index[(y[1] - rmin + 1, y[2] - cmin + 1)]
        rand(rng, Bool) && ((cx, cy) = (cy, cx))
        d = order[i]
        values[cx] = doms[d].a; values[cy] = doms[d].b
        push!(solution, Placement(d, cx, cy))
    end
    # G3–G4: regions and their initial (exact) rules
    regions = partition_regions(rng, board, prof.size_weights;
                                values = values, affinity = prof.equal_affinity)
    constraints = [initial_constraint(rng, values[r], prof) for r in regions]
    # G5: uniqueness
    make_unique!(rng, board, doms, regions, constraints, values, prof)
    # G6: assist – strengthen where the rater gets stuck above the target
    tgt = difficulty in LEVELS ? difficulty : nothing
    inst = Instance(board, doms, regions, constraints)
    rating = rate(inst, solution)
    for _ in 1:ncells(board)
        (tgt === nothing || levelindex(rating.level) <= levelindex(tgt)) && break
        assist!(board, regions, constraints, values, stuck_cell(rating, tgt))
        inst = make_unique!(rng, board, doms, regions, constraints, values, prof)
        rating = rate(inst, solution)
    end
    # G7: weakening (merge regions, weaker rules) while unique and not above target
    inst = loosen!(rng, board, doms, regions, constraints, values, prof;
                   solution = solution, target = tgt)
    @assert check_values(inst, values)
    # G8: final rating (generate() retries if the level misses the target)
    Puzzle(inst, solution, values, prof.maxpip, rate(inst, solution), difficulty, seed)
end

"""
    assist!(board, regions, constraints, values, cell)

Make the puzzle easier at `cell`: if its region's rule is NONE or an
inequality, replace it by the exact SUM (which implies it); otherwise pin the
cell (exact value). Pinning out of an `=`/`≠` region is not monotone, so the
caller re-runs `make_unique!` afterwards.
"""
function assist!(board, regions, constraints, values, cell)
    cell == 0 && return
    r = findfirst(reg -> cell in reg, regions)
    c = constraints[r]
    if c.kind in (NONE, LESS, GREATER)
        constraints[r] = Constraint(SUM, sum(values[regions[r]]))   # implies the old rule
    elseif length(regions[r]) > 1
        pin!(regions, constraints, r, cell, values, board)
    end
    nothing
end
