"""
    Dojuboga

Domino-placement puzzles in the style of NYT *Pips*: a generator with
guaranteed-unique solutions and rated difficulty, a front-end API for user
interfaces, and a terminal game.

* Play:        `play_terminal(:hard)`, or `julia --project=. play.jl hard` from a clone
* Front ends:  see API.md (`new_game`, queries, actions, `subscribe!`)
* Generation:  see SPEC.md (`generate`, `solve`, `rate`, `Profile`)
"""
module Dojuboga

using Random
import REPL

# engine
export Domino, Constraint, ConstraintKind, NONE, SUM, LESS, GREATER, EQUAL, NOTEQUAL,
       Board, Placement, Instance, Puzzle, Rating, Profile, PROFILES, LEVELS,
       generate, solve, is_unique, rate, check_values, satisfies, strength, label,
       show_puzzle, show_solution, full_set, ncells

# front-end API
export Game, GameEvent, new_game, subscribe!, unsubscribe!,
       puzzle, level, rating, seed,
       board_size, cell_coords, cell_at, neighbors,
       nregions, region_cells, region_of, region_rule, rule_label, rule_cell, region_colors,
       dominoes, ndominoes,
       location, domino_at, pip_at, tray, held, orientation, direction,
       can_place, preview, region_state, region_states,
       is_solved, was_revealed, elapsed, message,
       hold!, hold_next!, release!, turn!, place!, act!, remove!, hint!, clear!, reveal!

# terminal game
export play_terminal

include("engine/types.jl")
include("engine/constraints.jl")
include("engine/solver.jl")
include("engine/rating.jl")
include("engine/generator.jl")
include("engine/display.jl")
include("game.jl")
include("terminal/Terminal.jl")
using .Terminal: play_terminal

"""
    main(args) -> exit code

Command-line entry point: `args = [level, seed]`, both optional.
"""
function main(args::Vector{String} = ARGS)
    usage = "usage: julia --project=. play.jl [easy|medium|hard|expert] [seed]"
    if !isempty(args) && args[1] in ("-h", "--help")
        println(usage); return 0
    end
    lvl = length(args) >= 1 ? Symbol(lowercase(args[1])) : :medium
    if lvl ∉ LEVELS
        println(stderr, usage); return 1
    end
    sd = length(args) >= 2 ? tryparse(UInt64, args[2]) : nothing
    if length(args) >= 2 && sd === nothing
        println(stderr, "seed must be a non-negative integer\n", usage); return 1
    end
    play_terminal(lvl; seed = sd)
    0
end

end # module
