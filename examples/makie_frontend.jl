# A minimal graphical front end built only on the Dojuboga front-end API —
# the starting point for a GUI add-on. Not part of the package (Dojuboga itself
# has no graphics dependency).
#
#   julia> using GLMakie, Dojuboga          # or CairoMakie to render images
#   julia> include("examples/makie_frontend.jl")
#   julia> fig = MakieFrontend.run(new_game(:medium)); display(fig)
#
# Left-click a tray domino to hold it, left-click a cell to place / pick up,
# right-click or R to rotate, right-click a placed domino to return it.

module MakieFrontend

using Makie, Dojuboga

const PALETTE = [Makie.RGBf(c...) for c in [
    (0.98, 0.75, 0.55), (0.62, 0.80, 0.95), (0.80, 0.68, 0.93), (0.66, 0.88, 0.68),
    (0.99, 0.86, 0.45), (0.96, 0.62, 0.70), (0.55, 0.85, 0.85), (0.86, 0.80, 0.62),
    (0.75, 0.88, 0.50), (0.93, 0.70, 0.90)]]
const BLANK = Makie.RGBf(0.91, 0.89, 0.85)
const STATE_COLOR = Dict(:open => :gray30, :ok => :green4, :bad => :red3)

# geometry: cell (r,c) is centred at (c, -r); the tray sits below the board
cellxy(g, i) = (rc = cell_coords(g, i); Makie.Point2f(rc[2], -rc[1]))
slotxy(g, d) = Makie.Point2f(1 + 2.5 * ((d - 1) % 5), -(board_size(g)[1] + 2) - 1.4 * ((d - 1) ÷ 5))

function cell_under(g, p)
    c = round(Int, p[1]); r = round(Int, -p[2])
    (1 <= r <= board_size(g)[1] && 1 <= c <= board_size(g)[2]) ? cell_at(g, r, c) : 0
end
tray_under(g, p) = something(findfirst(d -> d in tray(g) &&
    abs(p[1] - slotxy(g, d)[1] - 0.5) <= 1 && abs(p[2] - slotxy(g, d)[2]) <= 0.5, 1:ndominoes(g)), 0)

function draw!(ax, g, hover)
    empty!(ax)
    cols = region_colors(g, length(PALETTE))
    rects = [Makie.Rect2f(cellxy(g, i) .- 0.5, (1, 1)) for i in 1:ncells(g)]
    poly!(ax, rects; color = [cols[region_of(g, i)] == 0 ? BLANK : PALETTE[cols[region_of(g, i)]]
                              for i in 1:ncells(g)], strokecolor = :white, strokewidth = 1)
    # placed dominoes: outline + pips as numbers
    for d in 1:ndominoes(g)
        loc = location(g, d); loc === nothing && continue
        a, b = cellxy(g, loc.a), cellxy(g, loc.b)
        lo = min.(a, b) .- 0.42; hi = max.(a, b) .+ 0.42
        poly!(ax, Makie.Rect2f(lo, hi .- lo); color = :ivory, strokecolor = :black, strokewidth = 1.5)
    end
    filled = [i for i in 1:ncells(g) if pip_at(g, i) !== nothing]
    isempty(filled) || text!(ax, [cellxy(g, i) for i in filled]; text = [string(pip_at(g, i)) for i in filled],
                             align = (:center, :center), fontsize = 0.5, markerspace = :data)
    # rules
    rs = [r for r in 1:nregions(g) if rule_label(g, r) != ""]
    text!(ax, [cellxy(g, rule_cell(g, r)) .+ Makie.Point2f(0.3, -0.32) for r in rs];
          text = [rule_label(g, r) for r in rs], color = [STATE_COLOR[region_state(g, r)] for r in rs],
          align = (:center, :center), fontsize = 0.26, markerspace = :data, font = :bold)
    # tray
    for d in tray(g)
        dom = dominoes(g)[d]
        text!(ax, slotxy(g, d) .+ Makie.Point2f(0.5, 0); text = "[$(dom.a)|$(dom.b)]",
              align = (:center, :center), fontsize = 0.45, markerspace = :data,
              color = d == held(g) ? :orange : :black, font = d == held(g) ? :bold : :regular)
    end
    # ghost of the held domino at the hovered cell
    pv = hover == 0 ? nothing : preview(g, hover)
    if pv !== nothing && pv.b != 0
        a, b = cellxy(g, pv.a), cellxy(g, pv.b)
        lo = min.(a, b) .- 0.42; hi = max.(a, b) .+ 0.42
        poly!(ax, Makie.Rect2f(lo, hi .- lo); color = (pv.fits ? :green : :red, 0.35))
    end
    (nr, nc) = board_size(g)
    limits!(ax, 0, max(nc, 12) + 1, slotxy(g, ndominoes(g))[2] - 1, 0)
end

"Open a front end on `game`; returns the Figure."
function run(game::Game)
    fig = Figure(size = (800, 800))
    ax = Axis(fig[1, 1]; aspect = DataAspect()); hidedecorations!(ax); hidespines!(ax)
    for i in (:rectanglezoom, :dragpan, :scrollzoom, :limitreset)
        try deregister_interaction!(ax, i) catch end
    end
    status = Label(fig[2, 1], ""; tellwidth = false)
    hover = Ref(0)
    redraw() = (draw!(ax, game, hover[]); status.text[] = message(game))
    subscribe!((g, ev) -> redraw(), game)          # the API tells us when to repaint
    on(events(fig).mousebutton) do ev
        (ev.action == Mouse.press && is_mouseinside(ax.scene)) || return Consume(false)
        p = mouseposition(ax.scene); cell = cell_under(game, p); d = tray_under(game, p)
        if ev.button == Mouse.left
            cell != 0 ? act!(game, cell) : d != 0 ? hold!(game, d) : release!(game)
        elseif ev.button == Mouse.right
            held(game) != 0 ? turn!(game) : cell != 0 && remove!(game, cell)
        end
        Consume(true)
    end
    on(events(fig).mouseposition) do _
        c = is_mouseinside(ax.scene) ? cell_under(game, mouseposition(ax.scene)) : 0
        c != hover[] && (hover[] = c; held(game) != 0 && redraw())
        Consume(false)
    end
    on(events(fig).keyboardbutton) do ev
        ev.action == Keyboard.press && ev.key == Keyboard.r && turn!(game)
        Consume(false)
    end
    redraw()
    fig
end

end # module
