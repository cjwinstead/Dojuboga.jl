# Dojuboga: Board Generation Specification

This document is normative for `src/engine/` in this repository. Section
labels **G1–G8** match the comments in `src/engine/generator.jl`.

---

## 1. The game

* **Board.** A set of unit cells on a square grid. The board has an even number
  of cells (2n) and is 4-connected.
* **Dominoes.** n dominoes, **pairwise distinct**, drawn from the double-*M* set
  (default *M* = 6, which gives the 28-piece double-six set). A domino `[a|b]` is
  unordered: `[2|5]` and `[5|2]` are the same piece.
* **Regions.** The cells are partitioned into connected regions. Each region
  carries one **rule**:

  | Rule | Symbol | Satisfied when the region's pips … |
  |---|---|---|
  | `SUM k`     | `k`  | sum to exactly k |
  | `LESS k`    | `<k` | sum to less than k |
  | `GREATER k` | `>k` | sum to more than k |
  | `EQUAL`     | `=`  | are all equal (region size ≥ 2) |
  | `NOTEQUAL`  | `≠`  | are pairwise different (region size ≥ 2) |
  | `NONE`      | none | anything (blank region) |

* **Goal.** Place every domino so that each one covers two adjacent cells, every
  cell is covered exactly once, and every region's rule holds.
* **Presentation.** The player sees the board, the regions with their rules, and
  the dominoes as an unordered collection (sorted by `(a,b)`, so the order reveals
  nothing).

## 2. Solution equivalence (what "unique" means)

A solution is identified by its **pip grid**: the vector of pip values, one per
cell. Two placements that produce the same pip grid are the **same solution**.
This covers two cases:

* a double rotated by 180°, and
* a *re-tiling*: different domino boundaries that show identical pips. For
  example, the 2×2 block `a b / b d` can be tiled with `[a|b]`,`[b|d]` either
  horizontally or vertically.

A puzzle is **unique** when exactly one pip grid satisfies all rules with
the given dominoes. The game accepts *any* valid arrangement as a win, so a
re-tiling is also accepted.

## 3. Generation pipeline

```
generate(level; seed):
  rng ← Xoshiro(seed)
  repeat up to 30 attempts:
     G1 grow a shape together with a tiling
     G2 pick n distinct dominoes, put them on the tiling   → reference solution
     G3 partition the cells into regions
     G4 give every region its strongest rule (exact sum)
     G5 tighten until the pip grid is unique
     G6 assist: strengthen where logic gets stuck above the target level
     G7 weaken (merge regions, weaker rules) while unique and ≤ target level
     G8 rate; if the level equals the target → return
  return the attempt whose level is closest to the target
```

The approach is **top-down**, like Sudoku generation: start with too much
information, which makes the puzzle unique and easy, then remove information for
as long as uniqueness holds and the difficulty ceiling is respected. Building
up from weak rules was tried first. It ended with most cells pinned to exact
values and rarely hit a target level.

All randomness comes from the single `rng`, so `(level, seed)` determines the
puzzle (see §8 for the caveat).

### G1 Shape and tiling

Inputs: n (drawn uniformly from `profile.ndominoes`), `compactness` c, and a
bounding-box limit `maxdim = ⌈√(4n)⌉`.

1. Place the first domino at the origin, horizontal or vertical with probability ½ each.
2. While fewer than n dominoes have been placed:
   * The **frontier** is the set of empty cells that are 4-adjacent to the shape
     and keep the bounding box within `maxdim × maxdim`.
   * Draw a frontier cell x with weight `c^(k−1)`, where k is the number of
     occupied neighbours of x. c > 1 favours compact, blobby shapes; c < 1
     favours stringy ones.
   * Draw a partner y among the empty, in-bounds neighbours of x with weight
     `1 + (occupied neighbours of y)`. Place the domino (x, y).
   * If x has no partner, remove x from the frontier and redraw. If the frontier
     empties, restart G1 from step 1.
3. Normalise the coordinates so the bounding box starts at (1,1). Index the cells
   in row-major order.

The shape is born together with a valid tiling, so a tiling always exists.
Holes and concavities arise naturally.

### G2 Dominoes and the reference solution

1. Shuffle the full double-*M* set and take the first n pieces. They are
   distinct by construction (requirement: every domino in a game is unique).
   Sort them for presentation.
2. Assign the pieces to the n tiling slots with a random permutation. For each
   slot, choose with probability ½ which cell shows `a` and which shows `b`.
3. Record the reference placements and the pip grid `V`.

### G3 Regions

1. Repeat until every cell is assigned:
   * **Seed:** among the unassigned cells (shuffled), pick the one with the fewest
     unassigned neighbours. This prevents stranded cells.
   * **Target size** s ~ `profile.size_weights` (the weight at index i is for size i).
   * **Grow** by adding an unassigned neighbour of the region until size s or no
     neighbour remains. A candidate f gets weight `1/(1 + free(f))`, where free(f)
     is its number of unassigned neighbours, so cells at risk of being cut off are
     taken first. While the region's pips are all equal so far, a candidate whose
     pip equals the seed's gets an extra factor `1 + equal_affinity`. This seeds
     `=` regions.
2. A region that ended with 1 cell although its target was larger is absorbed
   into its smallest neighbouring region.

Regions are independent of domino boundaries: a region may contain half a
domino, as in the NYT game.

### G4 Initial rules

Every region receives its most informative rule: `SUM(ΣV)`. If its pips are all
equal and its size is at least 2, it gets `=` instead with probability ½.

### G5 Uniqueness (tightening loop)

Repeat:

1. Run the exact solver (§4) with `limit = 2` distinct pip grids and a budget of
   300 000 nodes.
2. If exactly one grid is found and the search finished, stop.
3. If the budget ran out with no alternative found, set the weakest unpinned
   region (by information, §6) to its exact SUM (or pin one of its cells) and loop.
4. Otherwise let W be an alternative grid, D the cells where W ≠ V, and R_D the
   regions that touch D (shuffled). Apply the **first** move below that is
   possible. Each move keeps V valid and makes W invalid.

| Move | Action | Limit |
|---|---|---|
| (a) monotone strengthen | Replace a region's rule by one that implies the old rule and excludes W (`NONE` → anything; `<k` → `<k′` with k′ ≤ k, or the exact SUM; `>k` likewise). The profile's `tighten` setting picks the strongest or the weakest such rule. | none |
| (b) bisect | Split a region of 4–10 cells into two connected parts of at least 2 cells each. Each part gets the same kind of rule, re-derived (`=`/`≠` if still true, otherwise SUM; inequalities become tight). Accept only if the pair excludes W; prefer balanced splits. | none |
| (c) replace | Replace a region's rule by any non-blank rule that excludes W, preferring one with at least the old information. This is not monotone. | #regions |
| (d) carve pair | Cut an adjacent pair {c, y} with c ∈ D out of a region of at least 4 cells as `SUM(V_c+V_y)`. Requires V_c+V_y ≠ W_c+W_y and a connected remainder. | ⌊2n/4⌋ |
| (e) pin | Cut a single cell c ∈ D out as `SUM(V_c)`. The remainder splits into connected components with re-derived rules. | none |

**Termination.** Pinned cells (single-cell exact regions) are never changed
again, and a pin is only made at a cell where the alternative differs. Moves
(c) and (d) are capped, so after finitely many steps only (a), (b) and (e)
remain. (a) and (b) strictly shrink the solution set, and (e) strictly
increases the number of pinned cells. In the worst case every cell is pinned,
which is trivially unique.

### G6 Assist (difficulty ceiling)

Rate the puzzle (§5). While its level is above the target:

* Find the **stuck cell**: the most constrained empty cell at the moment the
  rater first needed a technique above the target's ceiling. For `easy` that is
  the first use of T3; for `medium`, the first T4 or the second round of T3; for
  `hard`, the first T4.
* Strengthen that cell's region: `NONE`/`<`/`>` becomes its exact SUM, which
  implies the old rule. Otherwise pin the cell.
* Re-run G5 (pinning out of an `=`/`≠` region is not monotone), then rate again.

The loop is limited to 2n iterations.

### G7 Weakening

Every change below is kept only if it passes the **acceptance test**: the
puzzle is still unique (G5 solver) **and** its rated level is not above the
target.

1. **Merge.** Up to `merge_tries` times: list the pairs of adjacent regions that
   both have rules and whose combined size is at most `length(size_weights)`.
   Sort them so the smallest regions come first (singletons first). For the first
   pair that passes, replace both with their union. The union's rule is tried in
   this order: `=` (if all its pips are equal), `≠` (if all are distinct, offered
   with probability ½), then `SUM`.
2. **Loosen.** Visit a fraction `loosen` of the regions in random order. For each,
   build at most one candidate per kind, each strictly less informative than the
   current rule:
   `NONE`, `<(ΣV+1+g)`, `>(ΣV−1−g)` with g ~ Geometric(mean = `slack`), and
   `=`/`≠` when they hold. Try them in a weighted-random order (weights
   `kind_weights`) and keep the first that passes the acceptance test.

### G8 Rating and acceptance

Rate the final instance (§5). `generate` returns the first attempt whose level
equals the target. After 30 attempts it returns the closest one; in practice
every attempt hits (§7).

## 4. Exact solver

* **State:** pip per cell (−1 = empty) and a used flag per domino.
* **Candidates:** every (unused domino, adjacent empty cells c1 < c2,
  orientation). Doubles are tried in one orientation only. A candidate is
  *legal* if both regions it touches stay **feasible**.
* **Feasibility of a region** (the only pruning rule). Let s be the sum of the
  filled cells, u the number of empty cells, and [lo, hi] the pip range of the
  dominoes not yet placed:
  * `SUM k`: s + u·lo ≤ k ≤ s + u·hi
  * `<k`: s + u·lo < k
  * `>k`: s + u·hi > k
  * `=`: the filled pips are equal, and that pip lies in [lo, hi] if u > 0
  * `≠`: the filled pips are distinct, and u ≤ the number of unseen values in [lo, hi]
* **Dead state:** some empty cell or some unused domino has no legal candidate.
  All dominoes must be used, since 2n cells means no spare pieces.
* **Branching:** on the empty cell **or** the unused domino with the fewest
  candidates (minimum remaining values). Both are complete branchings.
* Solutions are stored as pip grids in a set (§2). The search stops after
  `limit` distinct grids or `node_limit` nodes.

## 5. Difficulty metric

A human-style solver works with the same legal-candidate notion as the exact
solver and applies the cheapest technique available:

| Tech | Name | Applies when | Cost |
|---|---|---|---|
| T1 | forced cell | an empty cell has exactly one legal candidate | 1 |
| T2 | forced domino | an unused domino has exactly one legal candidate | 2 |
| T3 | lookahead | for every candidate touching a cell or domino with ≤ 4 options: place it, propagate T1/T2 to a fixpoint; a dead state eliminates the candidate | 6 per round that eliminates ≥ 1, plus 1 per elimination |
| T4 | guess | nothing else applies: commit to the reference solution's candidate at the most constrained cell (k options) | 12 · log₂ k |

**score** = the sum of costs until the board is full.

**level** (technique ceiling first, score second):

| Level | Condition |
|---|---|
| easy | T1/T2 only and score < 22 |
| medium | T1/T2 only with score ≥ 22, or exactly one T3 round |
| hard | two or more T3 rounds, no T4 |
| expert | at least one T4 (bifurcation needed) |

The rater also reports, for G6, the most constrained cell at the first T3, the
second T3 and the first T4, and the initial mean number of candidates per cell
(`branching`), which is a useful secondary "openness" measure.

*Soundness:* T1–T3 only remove options that appear in no solution, so on a
unique puzzle they never contradict the reference. The code asserts this.

## 6. Information content of a rule

`strength(rule, size, M) = −log₂ P(rule holds)` when each cell is an independent
uniform pip in `0:M`. For example, `NONE` = 0 bits, an exact single cell = log₂ 7 ≈ 2.81 bits,
and `=` over 3 cells = 2·log₂ 7. Sums use the exact convolution of uniforms.
This is used to order rules ("weaker", "strongest", "weakest region"); it is
not the difficulty measure.

## 7. Profiles and measured behaviour

| Profile | n | compactness | size weights (1,2,3,…) | kind weights (SUM,=,≠,<,>,none) | slack |
|---|---|---|---|---|---|
| easy   | 5–7   | 3.0 | 0.5, 4, 3, 1         | 5, 3, 1, 1, 1, 1     | 0.3 |
| medium | 7–9   | 3.0 | 0.5, 4, 4, 2, 1      | 4, 2, 1.5, 1.5, 1.5, 2 | 0.8 |
| hard   | 9–11  | 2.5 | 0.3, 3, 4, 3, 1.5    | 3, 2, 2, 2, 2, 3     | 1.2 |
| expert | 11–13 | 2.5 | 0.3, 2, 4, 4, 2, 1   | 2, 2, 2, 2, 2, 3     | 1.5 |

All profiles use M = 6, `loosen` = 1.0, `merge_tries` = 20 and `equal_affinity` = 4.

Measured over seeds 1–100 per level (Julia 1.9, one CPU core):

| Level | hit rate | n | score median (p10–p90) | branching | regions per domino | 1-cell regions | rule mix (SUM, =, ≠, <, >, none) | time median / max |
|---|---|---|---|---|---|---|---|---|
| easy   | 100% | 5–7   | 6 (5–8)      | 10.2 | 1.21 | 56% | 42, 2, 2, 22, 23, 9 % | 2 ms / 0.04 s |
| medium | 100% | 7–9   | 21 (17–24)   | 15.6 | 1.14 | 53% | 59, 2, 3, 13, 17, 6 % | 10 ms / 0.12 s |
| hard   | 100% | 9–11  | 44 (35–53)   | 19.0 | 1.14 | 51% | 64, 4, 3, 13, 11, 5 % | 51 ms / 0.6 s |
| expert | 100% | 11–13 | 126 (84–183) | 26.3 | 1.11 | 50% | 62, 5, 2, 12, 13, 6 % | 63 ms / 0.8 s |

Times exclude the one-off JIT compilation on the first call (≈5 s).

**Observation.** About one region per domino is needed for uniqueness. With 2n
cells and roughly n!·2ⁿ·(number of tilings) arrangements to exclude, a unique
puzzle needs on the order of log₂ of that in rule information, and exact sums
over large regions carry little. So about half of all regions end up as single
cells. This matches the look of the NYT puzzles. The partition itself creates
only about 4% singletons; the rest come from G5. Pushing this number down
means accepting fewer `<`/`>`/blank rules, or larger and more irregular boards
with fewer tilings.

## 8. Reproducibility

`generate(level; seed)` is deterministic for a given Julia version and package
version. Julia does not guarantee identical `Random` streams across releases,
so to archive a puzzle, store the instance itself (board coordinates, dominoes,
regions, rules), not just the seed.

## 9. Tuning levers and extensions

* **Custom difficulty:** pass `profile = Profile(...)` to `generate` with any
  `ndominoes`, `compactness`, `size_weights`, `kind_weights`, or a larger
  `maxpip` (pips above 6 are drawn as numerals). The rater still sets the
  level, so a custom profile only changes the flavour.
* **Finer control:** filter on `p.rating.score` (continuous) or
  `p.rating.branching` within a level.
* **Possible extensions:** disconnected boards (several islands); a rule kind
  for "each cell equals k"; a stronger T3 (depth 2) that would split today's
  `expert` level into "deep logic" and "true guessing"; and assigning dominoes
  in G2 so that equal pips meet across domino boundaries, which would yield
  more `=` regions.
