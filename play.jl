#!/usr/bin/env julia
# Play Dojuboga in the terminal (keyboard only; works over ssh).
#
#   julia --project=. play.jl [easy|medium|hard|expert] [seed]
#
# Set NO_COLOR=1 for terminals without 256-colour support.
using Dojuboga
exit(Dojuboga.main(ARGS))
