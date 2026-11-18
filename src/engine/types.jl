# ---------------------------------------------------------------------------
# Basic data types
# ---------------------------------------------------------------------------

"Grid coordinate `(row, col)`; rows grow downward, both 1-based."
const Coord = Tuple{Int,Int}

"""
    Domino(a, b)

An unordered domino. Stored canonically with `a <= b`, so `Domino(5,2) == Domino(2,5)`.
"""
struct Domino
    a::Int
    b::Int
    Domino(x::Integer, y::Integer) = x <= y ? new(x, y) : new(y, x)
end
Base.show(io::IO, d::Domino) = print(io, "[", d.a, "|", d.b, "]")
isdouble(d::Domino) = d.a == d.b

"All `(maxpip+1)(maxpip+2)/2` distinct dominoes with pips `0:maxpip` (28 for double-six)."
full_set(maxpip::Integer) = [Domino(a, b) for a in 0:maxpip for b in a:maxpip]

@enum ConstraintKind NONE SUM LESS GREATER EQUAL NOTEQUAL

"""
    Constraint(kind, k=0)

Region rule. `k` is the target for `SUM` (sum == k), `LESS` (sum < k) and
`GREATER` (sum > k); it is ignored for `NONE`, `EQUAL` (all pips equal) and
`NOTEQUAL` (all pips pairwise different).
"""
struct Constraint
    kind::ConstraintKind
    k::Int
end
Constraint(kind::ConstraintKind) = Constraint(kind, 0)

function label(c::Constraint)
    c.kind == NONE     && return ""
    c.kind == SUM      && return string(c.k)
    c.kind == LESS     && return "<" * string(c.k)
    c.kind == GREATER  && return ">" * string(c.k)
    c.kind == EQUAL    && return "="
    return "≠"
end
Base.show(io::IO, c::Constraint) = print(io, c.kind == NONE ? "·" : label(c))

"""
    Board(coords)

The playable cells. Coordinates are normalised so the bounding box starts at
(1,1); cells are indexed in row-major order.
"""
struct Board
    coords::Vector{Coord}
    index::Dict{Coord,Int}
    nbrs::Vector{Vector{Int}}
    nrows::Int
    ncols::Int
end

function Board(raw::AbstractVector{Coord})
    rmin = minimum(first, raw); cmin = minimum(last, raw)
    coords = sort!([(r - rmin + 1, c - cmin + 1) for (r, c) in raw])
    index = Dict(c => i for (i, c) in enumerate(coords))
    nbrs = [Int[index[n] for n in ((r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)) if haskey(index, n)]
            for (r, c) in coords]
    Board(coords, index, nbrs, maximum(first, coords), maximum(last, coords))
end
ncells(b::Board) = length(b.coords)

"A domino placed on two adjacent cells: `c1` shows `dominoes[domino].a`, `c2` shows `.b`."
struct Placement
    domino::Int
    c1::Int
    c2::Int
end

"""
    Instance

Everything the player is shown: board, the (unordered) dominoes, the regions
and their constraints. Contains no solution.
"""
struct Instance
    board::Board
    dominoes::Vector{Domino}
    regions::Vector{Vector{Int}}
    constraints::Vector{Constraint}
    region_of::Vector{Int}
end

function Instance(board::Board, dominoes, regions, constraints)
    region_of = zeros(Int, ncells(board))
    for (r, cells) in enumerate(regions), c in cells
        region_of[c] = r
    end
    Instance(board, dominoes, regions, constraints, region_of)
end

"Result of the human-style logical solver (see `rating.jl`)."
struct Rating
    score::Float64
    level::Symbol
    singles::Int           # T1 steps (cell with one option)
    hidden::Int            # T2 steps (domino with one option)
    lookahead_rounds::Int  # T3 rounds that eliminated something
    eliminations::Int      # options removed by T3
    guesses::Int           # T4 steps (bifurcation needed)
    branching::Float64     # mean options per cell at the start
    t3cell::Int            # most constrained cell when T3 was first needed (0 = never)
    t3cell2::Int           # … when T3 was needed for the second time
    t4cell::Int            # … when T4 (a guess) was first needed
end

"A generated puzzle: the instance plus a reference solution and its rating."
struct Puzzle
    inst::Instance
    solution::Vector{Placement}
    values::Vector{Int}    # pip value of every cell in the reference solution
    maxpip::Int
    rating::Rating
    difficulty::Symbol     # level requested
    seed::UInt64
end
