"""
    Dojuboga.Terminal

Full-screen terminal front end (ANSI, keyboard only; works over ssh).
It is written purely against the exported front-end API of `Dojuboga`
(`using ..Dojuboga` only), exactly like an external add-on would be.
"""
module Terminal

using ..Dojuboga
import REPL

export play_terminal

# Board layout on the character grid: cell (r,c) occupies text row 2r and
# columns 4c-2 … 4c; column 4c+1 and row 2r+1 are "gaps". Gaps inside a region
# take the region's colour (regions read as blocks); the gap between the two
# halves of a placed domino shows a link (━ or ┃).

const PALETTE  = [217, 153, 183, 151, 222, 216, 159, 187, 193, 225]  # 256-colour pastels
const BLANK_BG = 254
const INK      = 16
const FITS     = 114
const BLOCKED  = 210
const OK_FG    = 28
const BAD_FG   = 160
const DOT_FG   = 244
const ARROWS   = ('→', '↓', '←', '↑')
const LETTERS  = collect("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

struct Glyph
    ch::Char
    fg::Int          # 256-colour index, -1 = terminal default
    bg::Int
    bold::Bool
    rev::Bool
end
Glyph(ch::Char) = Glyph(ch, -1, -1, false, false)

"View state: the game plus the things only this front end cares about."
mutable struct View
    game::Game
    cursor::Tuple{Int,Int}   # (row, col); may sit on a hole so every cell is reachable
    colors::Vector{Int}      # per region: background colour (256-colour index)
    level::Symbol            # level for the next new game
    color::Bool
end

function View(g::Game; color::Bool = true)
    idx = region_colors(g, length(PALETTE))
    View(g, cell_coords(g, 1), [k == 0 ? BLANK_BG : PALETTE[k] for k in idx], level(g), color)
end

"Board cell under the cursor (0 on a hole)."
curcell(v::View) = cell_at(v.game, v.cursor...)

center3(s) = length(s) >= 3 ? first(s, 3) : length(s) == 2 ? s * " " : " " * s * " "

# --- rendering -----------------------------------------------------------------

function sgr(g::Glyph, color::Bool)
    codes = ["0"]
    g.bold && push!(codes, "1")
    g.rev && push!(codes, "7")
    if color
        g.fg >= 0 && push!(codes, "38;5;$(g.fg)")
        g.bg >= 0 && push!(codes, "48;5;$(g.bg)")
    end
    "\e[" * join(codes, ';') * "m"
end

function glyphline(gs, color::Bool)
    io = IOBuffer(); last = nothing
    for g in gs
        st = (g.fg, g.bg, g.bold, g.rev)
        st != last && (print(io, sgr(g, color)); last = st)
        print(io, g.ch)
    end
    print(io, "\e[0m")
    String(take!(io))
end

"The board as a matrix of glyphs."
function board_canvas(v::View)
    g = v.game; (nr, nc) = board_size(g)
    cv = fill(Glyph(' '), 2nr + 1, 4nc + 1)
    rulecells = Dict(rule_cell(g, r) => r for r in 1:nregions(g) if rule_label(g, r) != "")
    cc = curcell(v)
    # ghost of the held domino, .a half on the cursor
    ghost = Dict{Int,Int}(); gbg = FITS
    pv = cc == 0 || is_solved(g) ? nothing : preview(g, cc)
    if pv !== nothing
        dom = dominoes(g)[held(g)]
        gbg = pv.fits ? FITS : BLOCKED
        ghost[pv.a] = dom.a
        pv.b != 0 && (ghost[pv.b] = dom.b)
    end
    bgof(i) = v.color ? v.colors[region_of(g, i)] : -1
    fg = v.color ? INK : -1
    put!(y, x, s, fg, bg, bold = false, rev = false) =
        for (k, ch) in enumerate(s)
            cv[y, x+k-1] = Glyph(ch, fg, bg, bold, rev)
        end
    for i in 1:ncells(g)
        (r, c) = cell_coords(g, i); y = 2r; x = 4c - 2
        p = pip_at(g, i)
        if haskey(ghost, i)
            txt = i == cc ? "[" * string(ghost[i]) * "]" : center3(string(ghost[i]))
            put!(y, x, txt, INK, v.color ? gbg : -1, true, !v.color)
        elseif p !== nothing
            put!(y, x, center3(string(p)), fg, bgof(i), true, i == cc)
        elseif haskey(rulecells, i)
            put!(y, x, center3(rule_label(g, rulecells[i])), fg, bgof(i), false, i == cc)
        else
            mark = v.color ? "·" : string(LETTERS[mod1(region_of(g, i), 52)])
            put!(y, x, center3(mark), v.color ? DOT_FG : -1, bgof(i), false, i == cc)
        end
    end
    cc == 0 && put!(2v.cursor[1], 4v.cursor[2] - 2, "[ ]", -1, -1)
    linked(i, j) = (domino_at(g, i) != 0 && domino_at(g, i) == domino_at(g, j)) ||
                   (haskey(ghost, i) && haskey(ghost, j))
    gapbg(i, j) = haskey(ghost, i) && haskey(ghost, j) ? (v.color ? gbg : -1) :
                  region_of(g, i) == region_of(g, j) ? bgof(i) : -1
    linkfg(bg) = bg < 0 ? -1 : INK      # on the terminal's own background use its text colour
    for i in 1:ncells(g)
        (r, c) = cell_coords(g, i)
        j = cell_at(g, r, c + 1)                                   # horizontal gap
        j != 0 && put!(2r, 4c + 1, linked(i, j) ? "━" : " ", linkfg(gapbg(i, j)), gapbg(i, j), true)
        j = cell_at(g, r + 1, c)                                   # vertical gap
        j != 0 && put!(2r + 1, 4c - 2, linked(i, j) ? " ┃ " : "   ", linkfg(gapbg(i, j)), gapbg(i, j), true)
        q = (cell_at(g, r, c + 1), cell_at(g, r + 1, c), cell_at(g, r + 1, c + 1))
        if all(!=(0), q) && all(k -> region_of(g, k) == region_of(g, i), q)   # corner
            put!(2r + 1, 4c + 1, " ", INK, bgof(i))
        end
    end
    cv
end

"Legend: one line per ruled region, top-to-bottom."
function legend_lines(v::View)
    g = v.game
    rs = sort!([r for r in 1:nregions(g) if rule_label(g, r) != ""];
               by = r -> cell_coords(g, rule_cell(g, r)))
    cur = curcell(v) == 0 ? 0 : region_of(g, curcell(v))
    map(rs) do r
        sw = v.color ? "\e[48;5;$(v.colors[r])m  \e[0m" : string(LETTERS[mod1(r, 52)], ":")
        st = region_state(g, r)
        mark = st == :ok  ? (v.color ? "\e[1;38;5;$(OK_FG)m✓\e[0m" : "✓") :
               st == :bad ? (v.color ? "\e[1;38;5;$(BAD_FG)m✗\e[0m" : "✗") : " "
        sw * " " * rpad(rule_label(g, r), 4) * mark * (r == cur ? " ◀" : "  ")
    end
end

const HELP = [
    "move: arrows/hjkl   pick domino: Tab/n  Shift-Tab/p   rotate: r (R back)   place / pick up: Enter/Space",
    "remove: x   drop: Esc   hint: ?   clear: c   solution: S   new game: N, or 1-4 = easy…expert   quit: q"]

"The whole screen as a string (each line ends with clear-to-end-of-line)."
function render(v::View; width::Int = 100)
    g = v.game; (nr, nc) = board_size(g)
    out = String[]
    push!(out, "\e[1m Dojuboga — $(level(g)) · $(ndominoes(g)) dominoes · rating $(round(Int, rating(g).score))\e[0m")
    push!(out, "")
    board = [" " * glyphline(row, v.color) for row in eachrow(board_canvas(v))]
    legend = legend_lines(v)
    h = length(board); ncol = max(1, cld(length(legend), h))
    for k in 1:h
        line = board[k]
        for col in 1:ncol
            idx = (col - 1) * h + k
            idx <= length(legend) && (line *= "   " * legend[idx])
        end
        push!(out, line)
    end
    cc = curcell(v)
    if cc == 0
        push!(out, " cursor: outside the board")
    else
        r = region_of(g, cc); n = length(region_cells(g, r))
        push!(out, " cursor region: " * (rule_label(g, r) == "" ? "blank (no rule)" : rule_label(g, r)) *
                   " · $n cell$(n == 1 ? "" : "s")")
    end
    push!(out, "")
    per = max(1, (width - 8) ÷ 6)
    intray = Set(tray(g))
    items = map(1:ndominoes(g)) do d
        dom = dominoes(g)[d]; txt = "[$(dom.a)|$(dom.b)]"
        d ∉ intray ? " "^5 : d == held(g) ? "\e[1;7m$txt\e[0m" : txt
    end
    for (k, chunk) in enumerate(Iterators.partition(items, per))
        push!(out, (k == 1 ? " tray: " : "       ") * join(chunk, " "))
    end
    if held(g) != 0
        dom = dominoes(g)[held(g)]
        push!(out, " holding [$(dom.a)|$(dom.b)]  $(dom.a) $(ARROWS[orientation(g)+1]) $(dom.b)" *
                   "   (the [bracketed] half goes on the cursor; r rotates)")
    else
        push!(out, "")
    end
    push!(out, is_solved(g) && v.color ? " \e[1;38;5;$(OK_FG)m$(message(g))\e[0m" : " " * message(g))
    push!(out, "")
    append!(out, " \e[2m" .* HELP .* "\e[0m")
    join(out .* "\e[K", "\r\n")
end

# --- input ---------------------------------------------------------------------------

"Read one key: a `Char`, or a Symbol for special keys."
function readkey(io::IO)
    eof(io) && return :quit
    c = read(io, Char)
    if c == '\e'
        sleep(0.03)                                   # let the rest of a sequence arrive
        bytesavailable(io) == 0 && return :esc
        c2 = read(io, Char)
        if c2 == '[' || c2 == 'O'
            c3 = read(io, Char)
            c3 == 'A' && return :up
            c3 == 'B' && return :down
            c3 == 'C' && return :right
            c3 == 'D' && return :left
            c3 == 'Z' && return :backtab
            if isdigit(c3)                            # e.g. ESC [ 3 ~  (Delete)
                c4 = c3
                while c4 != '~' && bytesavailable(io) > 0
                    c4 = read(io, Char)
                end
                return c3 == '3' ? :delete : :unknown
            end
        end
        return :unknown
    end
    c in ('\r', '\n') && return :enter
    c == '\t' && return :tab
    c in ('\x7f', '\b') && return :backspace
    c in ('\x03', '\x04') && return :quit             # Ctrl-C, Ctrl-D
    c
end

"Move the cursor one step within the board's bounding box (holes included)."
function move!(v::View, dr::Int, dc::Int)
    (nr, nc) = board_size(v.game)
    v.cursor = (clamp(v.cursor[1] + dr, 1, nr), clamp(v.cursor[2] + dc, 1, nc))
end

"Apply one key. Returns `:quit`, `:new` (start a new game at `v.level`) or `:ok`."
function handle!(v::View, k)
    g = v.game; cc = curcell(v)
    k in (:quit, 'q') && return :quit
    if k in (:up, 'k');                  move!(v, -1, 0)
    elseif k in (:down, 'j');            move!(v, 1, 0)
    elseif k in (:left, 'h');            move!(v, 0, -1)
    elseif k in (:right, 'l');           move!(v, 0, 1)
    elseif k in (:tab, 'n');             hold_next!(g, 1)
    elseif k in (:backtab, 'p');         hold_next!(g, -1)
    elseif k == 'r';                     turn!(g, 1)
    elseif k == 'R';                     turn!(g, -1)
    elseif k in (:enter, ' ');           cc != 0 && act!(g, cc)
    elseif k in ('x', :backspace, :delete); cc != 0 && remove!(g, cc)
    elseif k == :esc;                    release!(g)
    elseif k == '?';                     hint!(g)
    elseif k == 'c';                     clear!(g)
    elseif k == 'S';                     reveal!(g)
    elseif k == 'N';                     return :new
    elseif k isa Char && '1' <= k <= '4'
        v.level = LEVELS[k - '0']; return :new
    end
    :ok
end

"""
    play_terminal(level=:medium; seed=nothing, color=true)

Play full-screen in the terminal. Colour needs a 256-colour terminal; pass
`color=false` (or set `NO_COLOR`) for plain text with lettered regions.
"""
function play_terminal(lvl::Symbol = :medium; seed = nothing,
                       color::Bool = !haskey(ENV, "NO_COLOR"),
                       input::IO = stdin, output::IO = stdout)
    term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", "xterm"), input, output, stderr)
    tty = input isa Base.TTY
    tty && REPL.Terminals.raw!(term, true)
    print(output, "\e[?1049h\e[?25l\e[H\e[2J Generating $lvl puzzle…")
    try
        v = View(new_game(lvl; seed = seed); color = color)
        while true
            width = output isa Base.TTY ? displaysize(output)[2] : 100
            print(output, "\e[H", render(v; width = width), "\e[J")
            res = handle!(v, readkey(input))
            res == :quit && break
            if res == :new
                print(output, "\e[H\e[2J Generating $(v.level) puzzle…")
                v = View(new_game(v.level); color = color)
            end
        end
    finally
        print(output, "\e[0m\e[?25h\e[?1049l")
        tty && REPL.Terminals.raw!(term, false)
    end
    nothing
end

end # module
