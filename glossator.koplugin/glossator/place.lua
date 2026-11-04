--[[--
Finding blank space on the page for an answer, near the ink it answers.

The page is a grid of cells, each either ink (text, figures, other notes) or
blank. A summed-area table answers "is this rectangle blank?" in constant
time, so every position of every candidate size can be tried. The best is the
blank rectangle closest to the ink, preferring the right, then below, then
the left, and last above.

Coordinates are "layout pixels": the screen's scale, with an origin that is
the page's top-left for a fixed page and the screen's for a reflowing one.
]]

local floor, ceil, max, min, sqrt = math.floor, math.ceil, math.max, math.min, math.sqrt

local Place = {}

-- An empty grid of cols x rows cells, each `cell` layout pixels square.
function Place.newGrid(cols, rows, cell)
    local occ = {}
    for i = 0, cols * rows - 1 do occ[i] = 0 end
    return { cols = cols, rows = rows, cell = cell, occ = occ }
end

--[[--
A grid from a blitbuffer: a cell is ink when any sampled pixel in its
`src_cell` x `src_cell` source pixels is darker than light grey.
]]
function Place.fromBB(bb, x0, y0, w, h, src_cell, layout_cell)
    local cols, rows = floor(w / src_cell), floor(h / src_cell)
    local g = Place.newGrid(cols, rows, layout_cell)
    local occ = g.occ
    local step = max(1, floor(src_cell / 3))
    for r = 0, rows - 1 do
        local py0 = y0 + r * src_cell
        for c = 0, cols - 1 do
            local px0 = x0 + c * src_cell
            local ink = false
            for yy = py0, py0 + src_cell - 1, step do
                for xx = px0, px0 + src_cell - 1, step do
                    local p = bb:getPixel(xx, yy)
                    if p and p:getColor8().a < 0xB0 then ink = true break end
                end
                if ink then break end
            end
            if ink then occ[r * cols + c] = 1 end
        end
    end
    return g
end

-- A copy of `g` (to mark notes on without changing the cached page).
function Place.copy(g)
    local occ = {}
    for i = 0, g.cols * g.rows - 1 do occ[i] = g.occ[i] end
    return { cols = g.cols, rows = g.rows, cell = g.cell, occ = occ }
end

-- `g` with `left` and `right` blank columns added.
function Place.widen(g, left, right)
    local out = Place.newGrid(g.cols + left + right, g.rows, g.cell)
    local W = out.cols
    for r = 0, g.rows - 1 do
        for c = 0, g.cols - 1 do
            out.occ[r * W + c + left] = g.occ[r * g.cols + c]
        end
    end
    return out
end

-- Mark a layout-pixel rect as taken, grown by `pad`.
function Place.mark(g, r, pad)
    pad = pad or 0
    local c0 = max(0, floor((r.x - pad) / g.cell))
    local r0 = max(0, floor((r.y - pad) / g.cell))
    local c1 = min(g.cols - 1, floor((r.x + r.w + pad) / g.cell))
    local r1 = min(g.rows - 1, floor((r.y + r.h + pad) / g.cell))
    for rr = r0, r1 do
        for cc = c0, c1 do g.occ[rr * g.cols + cc] = 1 end
    end
end

-- Grow every inked cell by `n` cells (so answers keep a little air).
function Place.dilate(g, n)
    if n <= 0 then return g end
    local out = Place.newGrid(g.cols, g.rows, g.cell)
    local cols, rows = g.cols, g.rows
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            if g.occ[r * cols + c] == 1 then
                for rr = max(0, r - n), min(rows - 1, r + n) do
                    for cc = max(0, c - n), min(cols - 1, c + n) do
                        out.occ[rr * cols + cc] = 1
                    end
                end
            end
        end
    end
    return out
end

-- Is a layout-pixel rect blank (and inside the grid)?
function Place.isFree(g, r)
    local c0, r0 = floor(r.x / g.cell), floor(r.y / g.cell)
    local c1, r1 = floor((r.x + r.w) / g.cell), floor((r.y + r.h) / g.cell)
    if c0 < 0 or r0 < 0 or c1 >= g.cols or r1 >= g.rows then return false end
    for rr = r0, r1 do
        for cc = c0, c1 do
            if g.occ[rr * g.cols + cc] == 1 then return false end
        end
    end
    return true
end

local function sat(g)
    local cols, rows = g.cols, g.rows
    local W = cols + 1
    local s = {}
    for i = 0, W * (rows + 1) - 1 do s[i] = 0 end
    for r = 1, rows do
        local run = 0
        for c = 1, cols do
            run = run + g.occ[(r - 1) * cols + (c - 1)]
            s[r * W + c] = s[(r - 1) * W + c] + run
        end
    end
    return s, W
end

-- Distance between two rects (0 when they touch or overlap), and on which
-- side of `t` the rect `a` lies.
local function gap(a, t)
    local dx = max(t.x - (a.x + a.w), a.x - (t.x + t.w), 0)
    local dy = max(t.y - (a.y + a.h), a.y - (t.y + t.h), 0)
    local side
    if a.x >= t.x + t.w - 4 then side = "right"
    elseif a.y >= t.y + t.h - 4 then side = "below"
    elseif a.x + a.w <= t.x + 4 then side = "left"
    else side = "above" end
    return sqrt(dx * dx + dy * dy), side
end

local SIDE_COST = { right = 0, below = 30, left = 50, above = 90 }

--[[--
The best blank place for one of `variants` (each { w, h, penalty }) near
`target`, in grid `g`. `inset` keeps clear of the grid's edges.
@return { x, y, w, h, variant, dist } or nil
]]
function Place.find(g, target, variants, inset)
    local s, W = sat(g)
    local cell = g.cell
    inset = ceil((inset or 0) / cell)
    local best
    for _i, v in ipairs(variants) do
        local cw, ch = ceil(v.w / cell), ceil(v.h / cell)
        for r = inset, g.rows - ch - inset, 2 do
            local r2 = r + ch
            for c = inset, g.cols - cw - inset, 2 do
                local c2 = c + cw
                local sum = s[r2 * W + c2] - s[r * W + c2] - s[r2 * W + c] + s[r * W + c]
                if sum == 0 then
                    local rect = { x = c * cell, y = r * cell, w = v.w, h = v.h }
                    local d, side = gap(rect, target)
                    local score = d + SIDE_COST[side] + (v.penalty or 0)
                    -- prefer starting level with the ink
                    if side == "right" or side == "left" then
                        score = score + max(0, rect.y - target.y) * 0.15 + max(0, target.y - rect.y) * 0.4
                    end
                    if not best or score < best.score then
                        best = { x = rect.x, y = rect.y, w = v.w, h = v.h, variant = v, dist = d, score = score, side = side }
                    end
                end
            end
        end
    end
    return best
end

return Place
