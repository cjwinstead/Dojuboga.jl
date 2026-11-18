# ---------------------------------------------------------------------------
# Plain-text rendering (useful in the REPL and for debugging)
# ---------------------------------------------------------------------------

const REGION_LETTERS = collect("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

"Print the board with region letters, the constraint list and the dominoes."
function show_puzzle(io::IO, inst::Instance; values = nothing)
    b = inst.board
    for r in 1:b.nrows
        for c in 1:b.ncols
            i = get(b.index, (r, c), 0)
            if i == 0
                print(io, "  . ")
            else
                reg = REGION_LETTERS[mod1(inst.region_of[i], length(REGION_LETTERS))]
                print(io, " ", reg, values === nothing ? "  " : string(values[i], " "))
            end
        end
        println(io)
    end
    println(io, "Regions: ", join(["$(REGION_LETTERS[mod1(r, 52)])=$(inst.constraints[r])"
                                   for r in eachindex(inst.regions)], "  "))
    println(io, "Dominoes: ", join(string.(inst.dominoes), " "))
end

function Base.show(io::IO, ::MIME"text/plain", p::Puzzle)
    r = p.rating
    println(io, "Dojuboga puzzle ($(length(p.inst.dominoes)) dominoes, requested $(p.difficulty), ",
            "rated $(r.level), score $(round(r.score; digits = 1)), seed $(p.seed))")
    show_puzzle(io, p.inst)
end

"Print the reference solution (pip values in each cell)."
show_solution(p::Puzzle; io::IO = stdout) = show_puzzle(io, p.inst; values = p.values)
