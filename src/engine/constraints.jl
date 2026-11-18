# ---------------------------------------------------------------------------
# Constraint evaluation, partial feasibility and information content
# ---------------------------------------------------------------------------

"Does a fully-filled region with pip values `vals` satisfy `c`?"
function satisfies(c::Constraint, vals)
    k = c.kind
    k == NONE     && return true
    k == SUM      && return sum(vals) == c.k
    k == LESS     && return sum(vals) < c.k
    k == GREATER  && return sum(vals) > c.k
    k == EQUAL    && return all(==(first(vals)), vals)
    return allunique(vals)
end

"Check a complete cell-value vector against every region of `inst`."
check_values(inst::Instance, vals) =
    all(satisfies(inst.constraints[r], vals[cells]) for (r, cells) in enumerate(inst.regions))

"""
    region_feasible(inst, vals, r, lo, hi)

Can region `r` still be satisfied, given the current partial assignment `vals`
(-1 = empty) and that every still-empty cell will receive a pip in `lo:hi`?
This is the *only* pruning rule used by both the exact solver and the
human-style rater, so both reason with the same local logic.
"""
function region_feasible(inst::Instance, vals::Vector{Int}, r::Int, lo::Int, hi::Int)
    c = inst.constraints[r]
    kind = c.kind
    kind == NONE && return true
    s = 0; u = 0; seen = UInt64(0); firstv = -1
    for cell in inst.regions[r]
        v = vals[cell]
        if v < 0
            u += 1
            continue
        end
        s += v
        if kind == EQUAL
            if firstv < 0
                firstv = v
            elseif v != firstv
                return false
            end
        elseif kind == NOTEQUAL
            bit = UInt64(1) << v
            (seen & bit) != 0 && return false
            seen |= bit
        end
    end
    if kind == SUM
        return s + u * lo <= c.k <= s + u * hi
    elseif kind == LESS
        return s + u * lo < c.k
    elseif kind == GREATER
        return s + u * hi > c.k
    elseif kind == EQUAL
        return u == 0 || firstv < 0 || lo <= firstv <= hi
    else # NOTEQUAL: remaining cells need distinct, unseen values in lo:hi
        u == 0 && return true
        avail = 0
        for v in lo:hi
            (seen >> v) & 1 == 0 && (avail += 1)
        end
        return u <= avail
    end
end

# --- information content -----------------------------------------------------

"Distribution of the sum of `n` iid uniform pips in `0:maxpip` (index = sum+1)."
function sum_distribution(n::Int, maxpip::Int)
    m = maxpip + 1
    d = [1.0]
    for _ in 1:n
        nd = zeros(length(d) + maxpip)
        for (i, p) in enumerate(d), v in 0:maxpip
            nd[i+v] += p / m
        end
        d = nd
    end
    d
end

"""
    strength(c, n, maxpip)

Information content (bits) of constraint `c` on a region of `n` cells:
`-log2 P(c holds)` when each cell is an independent uniform pip in `0:maxpip`.
`NONE` has strength 0; an exact sum on one cell has `log2(maxpip+1)`.
"""
function strength(c::Constraint, n::Int, maxpip::Int)
    m = maxpip + 1
    p = if c.kind == NONE
        1.0
    elseif c.kind == EQUAL
        float(m)^(1 - n)
    elseif c.kind == NOTEQUAL
        prod((m - i) / m for i in 0:n-1)
    else
        d = sum_distribution(n, maxpip)
        idx(k) = clamp(k, 0, length(d) - 1) + 1
        c.kind == SUM     ? (0 <= c.k < length(d) ? d[c.k+1] : 0.0) :
        c.kind == LESS    ? sum(d[1:idx(c.k - 1)]; init = 0.0) * (c.k > 0) :
                            sum(d[idx(c.k + 1):end]; init = 0.0) * (c.k < length(d) - 1)
    end
    -log2(max(p, 1e-12))
end

"""
    valid_constraints(vals, maxpip)

Every non-vacuous constraint that a region holding pip values `vals` satisfies
(plus `NONE`). Inequalities range over every non-trivial threshold.
"""
function valid_constraints(vals, maxpip)
    n = length(vals); s = sum(vals)
    out = Constraint[Constraint(NONE), Constraint(SUM, s)]
    for k in s+1:n*maxpip            # sum < k is non-vacuous only if k <= n*maxpip
        push!(out, Constraint(LESS, k))
    end
    for k in 0:s-1                   # sum > k is non-vacuous only if k >= 0
        push!(out, Constraint(GREATER, k))
    end
    if n >= 2
        all(==(vals[1]), vals) && push!(out, Constraint(EQUAL))
        allunique(vals) && push!(out, Constraint(NOTEQUAL))
    end
    out
end

"""
    implies(new, old)

Conservative test that every assignment satisfying `new` also satisfies `old`
(used to keep constraint tightening monotone).
"""
function implies(new::Constraint, old::Constraint)
    old.kind == NONE && return true
    new == old && return true
    if old.kind == LESS
        return (new.kind == LESS && new.k <= old.k) || (new.kind == SUM && new.k < old.k)
    elseif old.kind == GREATER
        return (new.kind == GREATER && new.k >= old.k) || (new.kind == SUM && new.k > old.k)
    end
    false
end
