--[[--
Painting ink so it looks like a pen on paper: a round nib in real millimetres,
a line that thins when it is drawn fast and tapers at both ends, smoothed when
the pen lifts, in crisp black (or a grainy pencil grey).

The approach follows Ink Away (ink/raster.lua and ink/pens.lua, MIT, see
NOTICE.md): filled discs stamped along the path, merged into one horizontal
span per row, so a line is round and solid at any width, and looks the same
under the e-ink panel's fast refresh while it is drawn as afterwards. (An
anti-aliased brush looked blocky there: the fast waveform turns its grey edge
pixels black.)

A stroke is a flat list x1, y1, x2, y2, ... with optional fields
  w     width, 1-3 (fine, medium, bold)
  q     per point, 0-255: how much of the full width (pressure, or simulated
        from speed); older strokes have p, 1-9, instead
  kind  "hl" for a marker stroke
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen

local floor, ceil, max, min, abs, sqrt, exp = math.floor, math.ceil, math.max, math.min, math.abs, math.sqrt, math.exp

local Paint = {}

Paint.INK = Blitbuffer.COLOR_BLACK
Paint.PENCIL = Blitbuffer.Color8(0x3A)
-- the marker multiplies the page by this grey: light, and the text shows through
Paint.MARKER = Blitbuffer.Color8(0xC4)

-- Pen widths, in mm: a fine-liner, a ballpoint, a felt pen.
Paint.WIDTH_MM = { 0.35, 0.55, 0.9 }
-- At no pressure (or drawn fast) the line keeps this much of its width.
local MINF = 0.5
-- The ends of a stroke thin over this many widths, down to TAPER_MIN.
local TAPER_A, TAPER_B, TAPER_MIN = 2.5, 3.0, 0.35

-- Screen pixels per mm, from the screen's real DPI (300 on a Kindle Scribe).
-- KOReader's scaleBySize is a UI scale, not a physical one: on the Scribe it
-- made every line about three times too wide.
function Paint.pxmm()
    local dpi = Screen.getDPI and Screen:getDPI() or 300
    if not dpi or dpi < 100 then dpi = 300 end
    return dpi / 25.4
end

-- "pen" (crisp black) or "pencil" (grainy grey, a little finer).
function Paint.style()
    return G_reader_settings and G_reader_settings:readSetting("inkai_ink_style") or "pen"
end

function Paint.inkColor()
    return Paint.style() == "pencil" and Paint.PENCIL or Paint.INK
end

-- The full radius in pixels of pen width 1-3.
function Paint.radius(w)
    local mm = Paint.WIDTH_MM[w or 2] or Paint.WIDTH_MM[2]
    if Paint.style() == "pencil" then mm = mm * 0.9 end
    return max(0.6, mm * Paint.pxmm() / 2)
end

function Paint.markerRadius()
    return max(3, floor(2.2 * Paint.pxmm() + 0.5)) -- a 4.4 mm chisel
end

-- How much of the full width at q (0-255).
function Paint.factor(q)
    if not q then return 1 end
    return MINF + (1 - MINF) * q / 255
end

-- Pressure from speed, for a pen without a pressure sensor: slow is full, fast
-- thins to 35% (Ink Away's curve). `speed` in mm per ms.
function Paint.fromSpeed(speed)
    local p = 1.05 - (speed or 0) * 2.3
    if p < 0.35 then p = 0.35 elseif p > 1 then p = 1 end
    return floor(p * 255 + 0.5)
end

-- Ease q from `prev` towards `q` over the distance moved (mm), so a jumpy
-- sample never leaves a blob.
function Paint.easeQ(prev, q, dist_mm)
    if not prev then return q end
    local k = 1 - exp(-(dist_mm or 0) / 1.2)
    return floor(prev + (q - prev) * k + 0.5)
end

-- A pen's raw pressure (the pen bridge reports it) to 0-255.
function Paint.fromRaw(raw, maxp)
    if not raw or not maxp or maxp <= 0 then return nil end
    local p = min(1, max(0, raw / maxp))
    return floor(p * 255 + 0.5)
end

-- How much of its width a stroke has `t` widths from its start and `e` from its
-- end (nil while it's being drawn): a smooth ramp at each end. Short strokes
-- get shorter ramps, and a dot keeps its full width.
local function ramp(t, len)
    if len <= 0 or t >= len then return 1 end
    local u = t / len
    u = u * u * (3 - 2 * u)
    return TAPER_MIN + (1 - TAPER_MIN) * u
end
function Paint.taper(t, e, total)
    local a, b = TAPER_A, TAPER_B
    if total then
        if total < 1.2 then return 1 end
        if total < a + b then
            local k = total / (a + b) * 0.8
            a, b = a * k, b * k
        end
    end
    local f = ramp(t, a)
    if e then f = min(f, ramp(e, b)) end
    return f
end

------------------------------------------------------------------------------
-- Spans
------------------------------------------------------------------------------

-- A stable pseudo-random value in [0,1) for pixel (x, y): the pencil's grain
-- (the same pixels every redraw, so it never flickers).
local bit = require("bit")
local band, bxor, rshift, tobit = bit.band, bit.bxor, bit.rshift, bit.tobit
local function hash01(x, y)
    local h = tobit(x * 374761393)
    h = tobit(h + tobit(y * 668265263))
    h = bxor(h, rshift(h, 13))
    h = tobit(h * 1274126177)
    h = bxor(h, rshift(h, 16))
    return band(h, 0xffff) / 65535
end

-- Paint row y from x0 to x1 (inclusive).
local function span(bb, x0, x1, y, color, grain)
    if x1 < x0 then return end
    if not grain then
        bb:paintRect(x0, y, x1 - x0 + 1, 1, color)
        return
    end
    -- the pencil: about three pixels in four, in runs
    local run
    for x = x0, x1 do
        if hash01(x, y) < 0.78 then
            run = run or x
        elseif run then
            bb:paintRect(run, y, x - run, 1, color)
            run = nil
        end
    end
    if run then bb:paintRect(run, y, x1 - run + 1, 1, color) end
end

-- One segment, radius r0 at (x0, y0) to r1 at (x1, y1): discs stamped about
-- every half pixel, merged into one span per row (the union of the discs is
-- convex, so each row is a single span).
local rowL, rowR = {}, {}
function Paint.segment(bb, x0, y0, x1, y1, r0, color, r1)
    r1 = r1 or r0
    r0, r1 = max(0.5, r0), max(0.5, r1)
    local dx, dy = x1 - x0, y1 - y0
    local len = sqrt(dx * dx + dy * dy)
    local n = max(1, ceil(len * 2))
    local ytop = floor(min(y0 - r0, y1 - r1))
    local ybot = ceil(max(y0 + r0, y1 + r1))
    for y = ytop, ybot do rowL[y], rowR[y] = math.huge, -math.huge end
    for i = 0, n do
        local t = i / n
        local cx, cy = x0 + dx * t, y0 + dy * t
        local r = r0 + (r1 - r0) * t
        local r2 = r * r
        local yc = floor(cy + 0.5)
        local xc = floor(cx + 0.5)
        local ir = floor(r)
        for d = -ir, ir do
            local half = floor(sqrt(max(0, r2 - d * d)) + 0.5)
            local y = yc + d
            local l, rr = xc - half, xc + half
            if l < rowL[y] then rowL[y] = l end
            if rr > rowR[y] then rowR[y] = rr end
        end
    end
    local grain = color == Paint.PENCIL
    for y = ytop, ybot do
        if rowL[y] <= rowR[y] then span(bb, rowL[y], rowR[y], y, color, grain) end
        rowL[y], rowR[y] = nil, nil
    end
end

-- A filled round dot.
function Paint.dot(bb, x, y, r, color)
    Paint.segment(bb, x, y, x, y, r, color, r)
end
Paint.dab = Paint.dot

------------------------------------------------------------------------------
-- Strokes
------------------------------------------------------------------------------

-- The per-point width share of a stroke, 0-255 (q, or the older p 1-9).
local function qOf(s)
    if s.q then return s.q end
    if s.p then
        local q = {}
        for i, v in ipairs(s.p) do q[i] = min(255, v * 28) end
        return q
    end
end
Paint.qOf = qOf

-- A Catmull-Rom spline through the points, `sub` samples per span: the line
-- curves through every point the pen reported instead of turning corners.
function Paint.smooth(s, sub)
    local n = #s / 2
    if n < 3 then return s end
    sub = sub or 2
    local function pt(i)
        i = max(1, min(n, i))
        return s[2 * i - 1], s[2 * i]
    end
    local q = qOf(s)
    local out, oq = {}, q and {} or nil
    for i = 1, n - 1 do
        local x0, y0 = pt(i - 1)
        local x1, y1 = pt(i)
        local x2, y2 = pt(i + 1)
        local x3, y3 = pt(i + 2)
        for k = 0, sub - 1 do
            local t = k / sub
            local t2, t3 = t * t, t * t * t
            out[#out + 1] = 0.5 * (2 * x1 + (-x0 + x2) * t + (2 * x0 - 5 * x1 + 4 * x2 - x3) * t2 + (-x0 + 3 * x1 - 3 * x2 + x3) * t3)
            out[#out + 1] = 0.5 * (2 * y1 + (-y0 + y2) * t + (2 * y0 - 5 * y1 + 4 * y2 - y3) * t2 + (-y0 + 3 * y1 - 3 * y2 + y3) * t3)
            if oq then oq[#oq + 1] = q[i] + (q[i + 1] - q[i]) * t end
        end
    end
    out[#out + 1], out[#out + 2] = pt(n)
    if oq then oq[#oq + 1] = q[n] end
    out.w, out.kind, out.q = s.w, s.kind, oq
    return out
end

-- Draw a whole stroke at (ox, oy).
function Paint.stroke(bb, ox, oy, s, smooth)
    if s.kind == "hl" then
        local r = Paint.markerRadius()
        local cols = {}
        if #s == 2 then Paint.markerSegment(bb, ox + s[1], oy + s[2], ox + s[1], oy + s[2], r, cols) end
        for i = 3, #s, 2 do
            Paint.markerSegment(bb, ox + s[i - 2], oy + s[i - 1], ox + s[i], oy + s[i + 1], r, cols)
        end
        return
    end
    if smooth then s = Paint.smooth(s) end
    local R = Paint.radius(s.w)
    local color = Paint.inkColor()
    local q = qOf(s)
    local n = #s / 2
    if n == 1 then
        Paint.dot(bb, ox + s[1], oy + s[2], R * Paint.factor(q and q[1]), color)
        return
    end
    -- each point's distance from the start, in widths, for the taper
    local d, total = { 0 }, 0
    local W = 2 * R
    for k = 2, n do
        total = total + sqrt((s[2 * k - 1] - s[2 * k - 3]) ^ 2 + (s[2 * k] - s[2 * k - 2]) ^ 2) / W
        d[k] = total
    end
    local function rad(k)
        return R * Paint.factor(q and q[k]) * Paint.taper(d[k], total - d[k], total)
    end
    local r0 = rad(1)
    for k = 1, n - 1 do
        local r1 = rad(k + 1)
        Paint.segment(bb, ox + s[2 * k - 1], oy + s[2 * k], ox + s[2 * k + 1], oy + s[2 * k + 2], r0, color, r1)
        r0 = r1
    end
end

-- The radius of the newest point of a stroke being drawn (no end taper yet).
function Paint.liveRadius(s)
    local R = Paint.radius(s.w)
    local q = s.q
    local n = #s / 2
    local len = s.len or 0
    return R * Paint.factor(q and q[n]) * Paint.taper(len / (2 * R))
end

------------------------------------------------------------------------------
-- The marker, and selection outlines
------------------------------------------------------------------------------

-- The marker: a flat band, multiplied into the page so text shows through.
-- It is laid down in thin columns, each painted once over the band's extent in
-- it, so crossings never build up into dark patches. `cols` remembers what was
-- painted (pass the same table while a stroke is drawn live).
function Paint.markerSegment(bb, x0, y0, x1, y1, r, cols)
    cols = cols or {}
    local w = max(2, floor(0.3 * Paint.pxmm()))
    local dx, dy = x1 - x0, y1 - y0
    local steps = max(abs(dx), abs(dy), 1)
    for i = 0, steps do
        local t = i / steps
        local x, y = x0 + dx * t, y0 + dy * t
        local c = floor(x / w)
        local top, bot = floor(y - r), floor(y + r)
        local col = cols[c]
        if not col then
            bb:paintRect(c * w, top, w, bot - top, Paint.MARKER, bb.setPixelMultiply)
            cols[c] = { top, bot }
        else
            -- only the part of the band this column doesn't have yet
            if top < col[1] then
                bb:paintRect(c * w, top, w, col[1] - top, Paint.MARKER, bb.setPixelMultiply)
                col[1] = top
            end
            if bot > col[2] then
                bb:paintRect(c * w, col[2], w, bot - col[2], Paint.MARKER, bb.setPixelMultiply)
                col[2] = bot
            end
        end
    end
    return cols
end

-- A dashed rectangle (the lasso's selection).
function Paint.dashedRect(bb, x, y, w, h, color)
    local dash = Screen:scaleBySize(8)
    local t = max(1, Screen:scaleBySize(1))
    for i = 0, w, 2 * dash do
        bb:paintRect(x + i, y, min(dash, w - i), t, color)
        bb:paintRect(x + i, y + h - t, min(dash, w - i), t, color)
    end
    for i = 0, h, 2 * dash do
        bb:paintRect(x, y + i, t, min(dash, h - i), color)
        bb:paintRect(x + w - t, y + i, t, min(dash, h - i), color)
    end
end

-- A dotted polyline (the lasso and the eraser while they are drawn).
function Paint.dotted(bb, pts, color)
    local gap = Screen:scaleBySize(6)
    local acc = 0
    for i = 3, #pts, 2 do
        local x0, y0, x1, y1 = pts[i - 2], pts[i - 1], pts[i], pts[i + 1]
        local len = sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
        local d = 0
        while d < len do
            if acc <= 0 then
                local t = d / len
                Paint.dot(bb, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, 1, color)
                acc = gap
            end
            local step = min(acc, len - d)
            d = d + max(step, 1)
            acc = acc - max(step, 1)
        end
    end
end

return Paint
