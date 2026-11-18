# ---------------------------------------------------------------------------
# Front-end API
#
# Everything a user interface needs: start a game, read the static puzzle
# (board, regions, rules, dominoes), read the play state, perform moves and be
# notified of changes. Front ends never touch `Game`'s fields directly; the
# terminal UI (src/terminal/) is built on these functions only. See API.md.
# ---------------------------------------------------------------------------

"""
    GameEvent(kind, domino)

Passed to subscribers after every state change. `kind` is one of
`:held, :released, :turned, :placed, :removed, :hint, :cleared, :revealed,
:solved, :rejected`; `domino` is the domino concerned (0 if none). `:rejected`
means a move was refused (see [`message`](@ref) for why).
"""
struct GameEvent
    kind::Symbol
    domino::Int
end

"""
    Game

One play session. Create with [`new_game`](@ref) or `Game(puzzle)`.
Treat it as opaque: use the query and action functions.
"""
mutable struct Game
    puzzle::Puzzle
    loc::Vector{Tuple{Int,Int}}   # per domino: (cell showing .a, cell showing .b); (0,0) = off the board
    occ::Vector{Int}              # per cell: domino index or 0
    held::Int
    orient::Int
    started::Float64
    finished::Float64             # time() at solve, 0 while unsolved
    revealed::Bool
    message::String
    listeners::Dict{Int,Function}
    nextid::Int
end

Game(p::Puzzle) = Game(p, fill((0, 0), length(p.inst.dominoes)), zeros(Int, ncells(p.inst.board)),
                       0, 0, time(), 0.0, false, "Pick a domino from the tray.",
                       Dict{Int,Function}(), 1)

"""
    new_game(level=:medium; seed=nothing, profile=nothing) -> Game

Generate a new puzzle (`level` ∈ `LEVELS`) and start a game on it. A `seed`
makes the puzzle reproducible; a custom [`Profile`](@ref) changes its flavour.
"""
function new_game(level::Symbol = :medium; seed = nothing, profile = nothing)
    level in LEVELS || throw(ArgumentError("level must be one of $LEVELS"))
    kw = (; (seed === nothing ? () : (seed = seed,))..., (profile === nothing ? () : (profile = profile,))...)
    Game(generate(level; kw...))
end

# --- events -------------------------------------------------------------------

"""
    subscribe!(f, game) -> id

Call `f(game, event::GameEvent)` after every change. Returns an id for
[`unsubscribe!`](@ref).
"""
function subscribe!(f::Function, g::Game)
    id = g.nextid; g.nextid += 1; g.listeners[id] = f
    id
end
unsubscribe!(g::Game, id::Int) = (delete!(g.listeners, id); nothing)

function emit(g::Game, kind::Symbol, d::Int = 0)
    ev = GameEvent(kind, d)
    for id in sort!(collect(keys(g.listeners)))
        g.listeners[id](g, ev)
    end
    nothing
end

reject(g::Game, msg::String) = (g.message = msg; emit(g, :rejected); false)

# --- static queries (fixed for the whole game) ---------------------------------

"The underlying generated [`Puzzle`](@ref) (instance, reference solution, rating)."
puzzle(g::Game) = g.puzzle
"Requested difficulty level."
level(g::Game) = g.puzzle.difficulty
"Difficulty [`Rating`](@ref) (`.score`, `.level`, technique counts)."
rating(g::Game) = g.puzzle.rating
"Seed the puzzle was generated from."
seed(g::Game) = g.puzzle.seed

"`(nrows, ncols)` of the board's bounding box."
board_size(g::Game) = (g.puzzle.inst.board.nrows, g.puzzle.inst.board.ncols)
ncells(g::Game) = ncells(g.puzzle.inst.board)
"`(row, col)` of cell `i` (rows grow downward, 1-based)."
cell_coords(g::Game, i::Int) = g.puzzle.inst.board.coords[i]
"Cell index at `(row, col)`, or 0 for a hole / outside the board."
cell_at(g::Game, row::Int, col::Int) = get(g.puzzle.inst.board.index, (row, col), 0)
"Indices of the cells adjacent to cell `i`."
neighbors(g::Game, i::Int) = g.puzzle.inst.board.nbrs[i]

nregions(g::Game) = length(g.puzzle.inst.regions)
"Cells of region `r`."
region_cells(g::Game, r::Int) = g.puzzle.inst.regions[r]
"Region containing cell `i`."
region_of(g::Game, i::Int) = g.puzzle.inst.region_of[i]
"The [`Constraint`](@ref) of region `r` (`kind == NONE` for a blank region)."
region_rule(g::Game, r::Int) = g.puzzle.inst.constraints[r]
"Display text of region `r`'s rule: `\"7\"`, `\"<4\"`, `\">9\"`, `\"=\"`, `\"≠\"`, or `\"\"` for blank."
rule_label(g::Game, r::Int) = label(g.puzzle.inst.constraints[r])
"Cell where region `r`'s rule is conventionally drawn: its bottom-right-most cell."
rule_cell(g::Game, r::Int) = (cs = g.puzzle.inst.regions[r];
                              cs[argmax([g.puzzle.inst.board.coords[i] for i in cs])])

"""
    region_colors(game, k) -> Vector{Int}

A colour index in `1:k` per region such that neighbouring ruled regions
differ (0 for blank regions). Stable for a given puzzle.
"""
region_colors(g::Game, k::Int) = color_regions(g.puzzle.inst, k; rng = Xoshiro(g.puzzle.seed))

"The dominoes, indexed `1:ndominoes(game)` (sorted; the index is the domino's id)."
dominoes(g::Game) = g.puzzle.inst.dominoes
ndominoes(g::Game) = length(g.puzzle.inst.dominoes)

# --- play-state queries ----------------------------------------------------------

"`(a = cell, b = cell)` where domino `d` lies (its `.a` and `.b` halves), or `nothing` if not on the board."
location(g::Game, d::Int) = g.loc[d][1] == 0 ? nothing : (a = g.loc[d][1], b = g.loc[d][2])
"Domino covering cell `i`, or 0."
domino_at(g::Game, i::Int) = g.occ[i]
"Pip shown on cell `i`, or `nothing` if it is empty."
function pip_at(g::Game, i::Int)
    d = g.occ[i]
    d == 0 ? nothing : g.loc[d][1] == i ? g.puzzle.inst.dominoes[d].a : g.puzzle.inst.dominoes[d].b
end
"Ids of the dominoes not on the board (including the held one), in order."
tray(g::Game) = [d for d in eachindex(g.loc) if g.loc[d][1] == 0]
"The held domino's id, or 0."
held(g::Game) = g.held
"Orientation of the held domino: 0, 1, 2, 3 = its `.b` half lies right, below, left, above its `.a` half."
orientation(g::Game) = g.orient
"`(drow, dcol)` from the held domino's `.a` half to its `.b` half."
direction(g::Game) = DIRS[g.orient+1]

const DIRS = ((0, 1), (1, 0), (0, -1), (-1, 0))

function _target(g::Game, cell::Int, o::Int)
    (r, c) = cell_coords(g, cell); (dr, dc) = DIRS[o+1]
    cell_at(g, r + dr, c + dc)
end

"Would the held domino fit with its `.a` half on `cell`?"
function can_place(g::Game, cell::Int)
    g.held == 0 && return false
    c2 = _target(g, cell, g.orient)
    c2 != 0 && g.occ[cell] == 0 && g.occ[c2] == 0
end

"""
    preview(game, cell) -> (a, b, fits) or nothing

Where the held domino would go with its `.a` half on `cell`: `b` is the cell
for the `.b` half (0 if off the board) and `fits` whether both are free.
`nothing` when no domino is held.
"""
preview(g::Game, cell::Int) =
    g.held == 0 ? nothing : (a = cell, b = _target(g, cell, g.orient), fits = can_place(g, cell))

"`:open` (not full), `:ok` (full, rule holds) or `:bad` (full, rule broken) for region `r`."
function region_state(g::Game, r::Int)
    v = [pip_at(g, i) for i in g.puzzle.inst.regions[r]]
    any(isnothing, v) ? :open : satisfies(g.puzzle.inst.constraints[r], Int.(v)) ? :ok : :bad
end
region_states(g::Game) = [region_state(g, r) for r in 1:nregions(g)]

"True once every domino is placed and every rule holds (any valid arrangement counts)."
is_solved(g::Game) = g.finished > 0
"True if the solution was revealed rather than found."
was_revealed(g::Game) = g.revealed
"Seconds since the game started (frozen once solved)."
elapsed(g::Game) = (g.finished > 0 ? g.finished : time()) - g.started
"Human-readable note about the last action (empty if none)."
message(g::Game) = g.message

# --- actions ------------------------------------------------------------------------
# Each returns `true` if the state changed, `false` if the move was refused
# (with the reason in `message(game)`). Nothing changes after the puzzle is
# solved except `clear!`.

function _put!(g::Game, d::Int, c1::Int, c2::Int)
    g.loc[d] = (c1, c2); g.occ[c1] = d; g.occ[c2] = d
end
function _lift!(g::Game, d::Int)
    (c1, c2) = g.loc[d]
    c1 == 0 && return
    g.occ[c1] = 0; g.occ[c2] = 0; g.loc[d] = (0, 0)
end
function _orientation_of(g::Game, d::Int)
    (r1, c1) = cell_coords(g, g.loc[d][1]); (r2, c2) = cell_coords(g, g.loc[d][2])
    findfirst(==((r2 - r1, c2 - c1)), DIRS) - 1
end
domname(g::Game, d) = (dom = g.puzzle.inst.dominoes[d]; "[$(dom.a)|$(dom.b)]")

function _check_solved!(g::Game)
    all(l -> l[1] != 0, g.loc) || return false
    vals = [pip_at(g, i) for i in 1:ncells(g)]
    if check_values(g.puzzle.inst, vals)
        g.finished = time()
        t = round(Int, elapsed(g))
        g.message = g.revealed ? "Solution shown." : "Solved in $(t ÷ 60):$(lpad(t % 60, 2, '0'))!"
        emit(g, :solved)
        return true
    end
    g.message = "All dominoes placed, but some regions are not satisfied."
    false
end

"""
    hold!(game, d)

Take domino `d` in hand: from the tray, or off the board (keeping its
orientation). A previously held domino goes back to the tray.
"""
function hold!(g::Game, d::Int)
    is_solved(g) && return false
    1 <= d <= ndominoes(g) || throw(BoundsError(dominoes(g), d))
    if g.loc[d][1] != 0
        g.orient = _orientation_of(g, d); _lift!(g, d)
    end
    g.held = d; g.message = "Holding $(domname(g, d))."
    emit(g, :held, d); true
end

"Hold the next (`step = 1`) or previous (`-1`) domino in the tray, cycling."
function hold_next!(g::Game, step::Int = 1)
    is_solved(g) && return false
    t = tray(g)
    isempty(t) && return reject(g, "All dominoes are on the board.")
    k = findfirst(==(g.held), t)
    hold!(g, k === nothing ? (step > 0 ? first(t) : last(t)) : t[mod1(k + step, length(t))])
end

"Put the held domino back in the tray."
function release!(g::Game)
    g.held == 0 && return false
    d = g.held; g.held = 0; g.message = ""
    emit(g, :released, d); true
end

"Rotate the held domino by `step` quarter turns clockwise (negative = anticlockwise)."
function turn!(g::Game, step::Int = 1)
    (g.held == 0 || is_solved(g)) && return false
    g.orient = mod(g.orient + step, 4)
    emit(g, :turned, g.held); true
end

"Place the held domino with its `.a` half on `cell`."
function place!(g::Game, cell::Int)
    is_solved(g) && return false
    g.held == 0 && return reject(g, "No domino in hand.")
    can_place(g, cell) || return reject(g, "It doesn't fit there.")
    d = g.held
    _put!(g, d, cell, _target(g, cell, g.orient)); g.held = 0; g.message = ""
    emit(g, :placed, d)
    _check_solved!(g)
    true
end

"""
    act!(game, cell)

The "click" on a board cell: place the held domino there; if it doesn't fit
but the cell is covered, swap (hold the covering domino instead); with
nothing held, pick up the domino on the cell.
"""
function act!(g::Game, cell::Int)
    is_solved(g) && return false
    if g.held != 0
        can_place(g, cell) && return place!(g, cell)
        g.occ[cell] != 0 && return hold!(g, g.occ[cell])
        return reject(g, "It doesn't fit there.")
    end
    g.occ[cell] != 0 && return hold!(g, g.occ[cell])
    false
end

"Send the domino covering `cell` back to the tray."
function remove!(g::Game, cell::Int)
    (is_solved(g) || g.occ[cell] == 0) && return false
    d = g.occ[cell]; _lift!(g, d); g.message = "Returned $(domname(g, d)) to the tray."
    emit(g, :removed, d); true
end

"Place one domino of the reference solution, moving anything in its way."
function hint!(g::Game)
    is_solved(g) && return false
    sol = g.puzzle.solution
    correct(p) = Set(g.loc[p.domino]) == Set((p.c1, p.c2)) && pip_at(g, p.c1) == g.puzzle.values[p.c1]
    todo = [p for p in sol if !correct(p)]
    isempty(todo) && return false
    p = rand(todo)
    g.held == p.domino && (g.held = 0)
    for c in (p.c1, p.c2)
        g.occ[c] != 0 && _lift!(g, g.occ[c])
    end
    _lift!(g, p.domino); _put!(g, p.domino, p.c1, p.c2)
    g.message = "Hint: placed $(domname(g, p.domino))."
    emit(g, :hint, p.domino)
    _check_solved!(g)
    true
end

"Return every domino to the tray (also un-solves a solved board)."
function clear!(g::Game)
    foreach(d -> _lift!(g, d), eachindex(g.loc))
    g.held = 0; g.finished = 0.0; g.revealed = false; g.started = time()
    g.message = "Board cleared."
    emit(g, :cleared); true
end

"Show the reference solution (ends the game)."
function reveal!(g::Game)
    is_solved(g) && return false
    g.held = 0
    foreach(d -> _lift!(g, d), eachindex(g.loc))
    for p in g.puzzle.solution
        _put!(g, p.domino, p.c1, p.c2)
    end
    g.revealed = true
    emit(g, :revealed)
    _check_solved!(g)
    true
end

# --- helpers --------------------------------------------------------------------------

"""
    color_regions(inst, K; rng) -> Vector{Int}

Greedy colouring with `K` colours: neighbouring ruled regions differ, and the
least-used allowed colour is chosen. Blank regions get 0.
"""
function color_regions(inst::Instance, K::Int; rng = Random.default_rng())
    b = inst.board; nreg = length(inst.regions)
    adj = [Set{Int}() for _ in 1:nreg]
    for (i, nb) in enumerate(b.nbrs), j in nb
        ri, rj = inst.region_of[i], inst.region_of[j]
        ri != rj && (push!(adj[ri], rj); push!(adj[rj], ri))
    end
    idx = zeros(Int, nreg); uses = zeros(Int, K)
    for r in sortperm(length.(inst.regions); rev = true)
        inst.constraints[r].kind == NONE && continue
        used = Set(idx[t] for t in adj[r])
        allowed = [k for k in 1:K if k ∉ used]
        isempty(allowed) && (allowed = collect(1:K))
        k = allowed[argmin(uses[allowed] .+ rand(rng, length(allowed)))]
        idx[r] = k; uses[k] += 1
    end
    idx
end

function Base.show(io::IO, g::Game)
    print(io, "Game(", level(g), ", ", ndominoes(g), " dominoes, ",
          count(l -> l[1] != 0, g.loc), " placed", is_solved(g) ? ", solved" : "", ")")
end
