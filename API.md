# Dojuboga: Front-end API

This is the interface for writing a user interface (a GUI add-on, a web front end, a
bot) on top of the Dojuboga engine. The terminal game in `src/terminal/` is itself a
client of this API: it loads `Dojuboga` with `using ..Dojuboga` and touches nothing else.
So anything the terminal game can do, an add-on can do too.

**Stability.** The exported functions and types listed here are the API.
`Game`'s fields are private and may change. Breaking changes to this list will
bump the minor version while the package is 0.x.

## Concepts

| Term | Meaning |
|---|---|
| **cell** | An integer `1:ncells(g)`. `cell_coords(g, i)` gives `(row, col)`; rows grow downward and both are 1-based. The board is irregular, so `cell_at(g, row, col)` returns 0 for a hole. |
| **region** | An integer `1:nregions(g)`. A connected set of cells with one **rule** (`region_rule`, displayed as `rule_label`: `"7"`, `"<4"`, `">9"`, `"="`, `"≠"`, or `""` for a blank region). |
| **domino** | An integer id `1:ndominoes(g)`. `dominoes(g)[d]` is a `Domino` with halves `.a ≤ .b`. All dominoes in a game are distinct. |
| **tray** | The dominoes not on the board, as `tray(g)`. |
| **held domino** | At most one domino is "in hand" (`held(g)`, 0 = none). It is placed with its **`.a` half on a chosen cell**, and its `.b` half goes in the direction given by `orientation(g)`. |
| **orientation** | 0, 1, 2, 3 means the `.b` half lies right, below, left or above the `.a` half. `direction(g)` gives the same as `(drow, dcol)`. `turn!` rotates it clockwise. |
| **solved** | Every domino is placed and every rule holds. Any valid arrangement counts, not just the reference one. |

## The loop every front end follows

```julia
using Dojuboga
g = new_game(:hard)                          # or new_game(:hard; seed = 42)
subscribe!((g, ev) -> repaint(g), g)         # repaint whenever something changes
repaint(g)
# … map user input to actions:
#   click on tray domino d      → hold!(g, d)
#   click on board cell i       → act!(g, i)        (place / swap / pick up)
#   rotate key / right-click    → turn!(g)
#   "return to tray" on cell i  → remove!(g, i)
#   hover over cell i           → preview(g, i)     (draw a ghost; no state change)
```

`repaint` uses only the query functions below. Actions never block: they
return `true` if the state changed, or `false` if the move was refused, with
the reason in `message(g)` and a `:rejected` event.

## Reference

### Starting a game

| Function | Returns |
|---|---|
| `new_game(level = :medium; seed, profile)` | a new `Game`. `level ∈ LEVELS = (:easy, :medium, :hard, :expert)`. A `seed` makes it reproducible; a custom `Profile` changes the puzzle's flavour (see SPEC.md). |
| `Game(puzzle)` | a game on an existing `Puzzle` (for example, one from `generate`). |

### Static queries (fixed for a game)

| Function | Returns |
|---|---|
| `level(g)`, `seed(g)`, `rating(g)`, `puzzle(g)` | requested level · seed · `Rating` (`.score`, `.level`, …) · the underlying `Puzzle` |
| `board_size(g)` | `(nrows, ncols)` of the bounding box |
| `ncells(g)`, `cell_coords(g, i)`, `cell_at(g, row, col)`, `neighbors(g, i)` | board geometry |
| `nregions(g)`, `region_cells(g, r)`, `region_of(g, i)` | regions |
| `region_rule(g, r)`, `rule_label(g, r)` | the rule as a `Constraint` · as display text |
| `rule_cell(g, r)` | where to draw the rule: the region's bottom-right-most cell |
| `region_colors(g, k)` | a colour index `1:k` per region; neighbouring ruled regions differ, blank regions get 0. Stable for a puzzle. |
| `ndominoes(g)`, `dominoes(g)` | the pieces |

### Play-state queries

| Function | Returns |
|---|---|
| `tray(g)` | ids of the dominoes off the board, held one included |
| `held(g)`, `orientation(g)`, `direction(g)` | the domino in hand (0 = none) and how it is turned |
| `location(g, d)` | `(a = cell, b = cell)` for a placed domino, else `nothing` |
| `domino_at(g, i)`, `pip_at(g, i)` | what covers cell `i` (0 / `nothing` if empty) |
| `preview(g, i)` | `(a, b, fits)`: where the held domino would land with its `.a` half on `i`, with `b == 0` if off the board. `nothing` if nothing is held. |
| `can_place(g, i)` | `preview(g, i).fits` without the tuple |
| `region_state(g, r)`, `region_states(g)` | `:open` (not full), `:ok` (full and satisfied), `:bad` (full and broken) |
| `is_solved(g)`, `was_revealed(g)` | finished? · finished by `reveal!`? |
| `elapsed(g)` | seconds since start, frozen once solved |
| `message(g)` | a short human-readable note about the last action |

### Actions

| Function | Effect |
|---|---|
| `hold!(g, d)` | Take domino `d` in hand: from the tray, or off the board, keeping its orientation. |
| `hold_next!(g, step = 1)` | Hold the next (`-1`: previous) domino in the tray, cycling. |
| `release!(g)` | Put the held domino back in the tray. |
| `turn!(g, step = 1)` | Rotate the held domino by quarter turns, clockwise for positive `step`. |
| `place!(g, i)` | Place the held domino with its `.a` half on cell `i`. |
| `act!(g, i)` | The "click": place if it fits; otherwise, if `i` is covered, hold that domino instead (a swap); with nothing held, pick up the domino on `i`. |
| `remove!(g, i)` | Send the domino on cell `i` back to the tray. |
| `hint!(g)` | Place one domino of the reference solution, moving anything in its way. |
| `clear!(g)` | Return all dominoes to the tray and restart the clock. This also works after solving. |
| `reveal!(g)` | Show the reference solution, which ends the game. |

After the puzzle is solved, every action except `clear!` is refused.

### Events

`subscribe!(f, g)` registers `f(g, ev::GameEvent)` and returns an id for
`unsubscribe!(g, id)`. `ev.kind` is one of `:held`, `:released`, `:turned`,
`:placed`, `:removed`, `:hint`, `:cleared`, `:revealed`, `:solved` or
`:rejected`, and `ev.domino` is the domino concerned (0 if none). A move that
completes the puzzle emits its own event and then `:solved`. Listeners run
synchronously, inside the action call, in subscription order.

A `Game` is not thread-safe. Call actions from one task, such as your toolkit's
event loop.

## Writing a GUI add-on

`examples/makie_frontend.jl` is a complete working front end in about 120 lines
(board, rules, tray, ghost preview, clicks, repaint on events). It is tested
by rendering with CairoMakie and solving a puzzle with simulated clicks. To
turn it into an add-on package:

```
DojubogaMakie/
  Project.toml      # [deps] Dojuboga, GLMakie
  src/DojubogaMakie.jl  # module DojubogaMakie; using GLMakie, Dojuboga; … ; play_window(level) end
```

Develop it against your local engine with `Pkg.develop(path = "../Dojuboga")`. A
package extension (`[weakdeps] GLMakie` plus an `[extensions]` entry in Dojuboga'
own Project.toml) would also work. It would make `Dojuboga.play_window` appear
when GLMakie is loaded, without ever adding GLMakie to the terminal app's
dependencies.

**Naming note.** The API avoids names that common GUI and linear-algebra
packages export. For example, the rotation action is `turn!`, because
`rotate!` is exported by Makie and LinearAlgebra and would be ambiguous.
