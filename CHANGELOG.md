# Changelog

## 0.1.0 — first release

- Puzzle generator: random board shapes grown with a guaranteed tiling, distinct
  dominoes, connected regions with sum / `<` / `>` / `=` / `≠` / blank rules.
- Unique solutions (as pip grids), enforced by an exact solver.
- Four difficulty levels (easy, medium, hard, expert), rated by a human-style
  logical solver and hit by directed tightening/weakening (see SPEC.md).
- Front-end API (`Game`, queries, actions, events) for user interfaces (see API.md).
- Full-screen terminal game (`play_terminal`, `play.jl`), keyboard only; works over ssh.
- Example Makie front end (`examples/makie_frontend.jl`).
- Released under the MIT license.
