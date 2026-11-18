# Print a puzzle, its rating and its solution as text.
#   julia --project=. examples/print_puzzle.jl hard 42
using Dojuboga
lvl = length(ARGS) >= 1 ? Symbol(ARGS[1]) : :medium
sd  = length(ARGS) >= 2 ? parse(UInt64, ARGS[2]) : rand(UInt64)
p = generate(lvl; seed = sd)
display(p)
println("\nRating: ", p.rating)
println("\nSolution:"); show_solution(p)
