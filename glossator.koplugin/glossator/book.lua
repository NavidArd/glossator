--[[--
Where ink and answers go on the book, and where they come back.

Ink is drawn on the screen. To keep it with the text when the book is laid
out again, each group of strokes is saved against an anchor (after Ink Away's
ink/reader/place.lua, MIT):

  * a fixed-page book (PDF, DjVu): the page and the points in the page's own
    units, so zoom, scroll mode or a turned screen keep it on the same spot of
    the page. Both single-page and continuous-scroll views are handled (in
    single-page view ReaderView:pageToScreenTransform ignores the page number,
    so the page is checked here).
  * a reflowing book (EPUB...): the word nearest the ink, by its xpointers,
    and the ink's offset from that word's box, so the ink moves with its word.

Free space for an answer is found on an occupancy grid: for a fixed page from
a small rendering of the whole page (stable while scrolling), for a reflowing
page from the screen itself.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local logger = require("logger")
local Screen = Device.screen

local floor, max, min = math.floor, math.max, math.min

local Book = {}
Book.__index = Book

function Book.new(ui)
    return setmetatable({ ui = ui }, Book)
end

function Book:paging()
    return self.ui.paging ~= nil
end

------------------------------------------------------------------------------
-- Fixed pages
------------------------------------------------------------------------------

-- The page under screen point (x, y): page, px, py (page units), zoom.
function Book:toPage(x, y)
    local view = self.ui.view
    local ok, pos = pcall(view.screenToPageTransform, view, { x = x, y = y })
    if not (ok and pos and pos.page) then return nil end
    return pos.page, pos.x, pos.y, pos.zoom or (view.state and view.state.zoom) or 1
end

-- Where page point (px, py) is on the screen now: sx, sy, zoom; nil when the
-- page is not shown.
function Book:toScreen(page, px, py)
    local view = self.ui.view
    if view.page_scroll then
        local y = 0
        for _i, st in ipairs(view.page_states or {}) do
            if st.page == page then
                return st.offset.x + px * st.zoom - st.visible_area.x,
                    y + st.offset.y + py * st.zoom - st.visible_area.y, st.zoom
            end
            y = y + st.visible_area.h + (view.page_gap and view.page_gap.height or 0)
        end
        return nil
    end
    local st = view.state
    if not (st and st.page == page and view.visible_area) then return nil end
    return st.offset.x + px * st.zoom - view.visible_area.x,
        st.offset.y + py * st.zoom - view.visible_area.y, st.zoom
end

-- The pages on the screen now.
function Book:visiblePages()
    local ui = self.ui
    if ui.paging then
        local view = ui.view
        if view.page_scroll and view.page_states and #view.page_states > 0 then
            local pages = {}
            for _i, st in ipairs(view.page_states) do pages[#pages + 1] = st.page end
            return pages
        end
        return { view.state and view.state.page or ui.paging.current_page }
    end
    local ok, p = pcall(ui.document.getCurrentPage, ui.document)
    return { ok and p or 0 }
end

function Book:currentPage()
    return self:visiblePages()[1]
end

-- What changes where things go on the screen.
function Book:layoutKey()
    local ui = self.ui
    local parts = { Screen:getWidth(), Screen:getHeight() }
    if ui.paging then
        local view = ui.view
        local states = view.page_scroll and view.page_states or { view.state or {} }
        for _i, st in ipairs(states) do
            local va = view.page_scroll and st.visible_area or view.visible_area or {}
            local off = st.offset or {}
            parts[#parts + 1] = table.concat({ st.page or 0, st.zoom or 0, st.rotation or 0,
                va.x or 0, va.y or 0, off.x or 0, off.y or 0 }, ",")
        end
        return "p|" .. table.concat(parts, "|")
    end
    local ok, hash = pcall(ui.document.getDocumentRenderingHash, ui.document, false)
    local okp, pos = pcall(ui.document.getCurrentPos, ui.document)
    parts[#parts + 1] = ok and tostring(hash) or ""
    parts[#parts + 1] = okp and tostring(pos) or ""
    return "r|" .. table.concat(parts, "|")
end

------------------------------------------------------------------------------
-- Anchoring
------------------------------------------------------------------------------

local function bboxOf(strokes)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _i, s in ipairs(strokes) do
        for i = 1, #s, 2 do
            local x, y = s[i], s[i + 1]
            if x < x0 then x0 = x end
            if x > x1 then x1 = x end
            if y < y0 then y0 = y end
            if y > y1 then y1 = y end
        end
    end
    if x0 > x1 then return nil end
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end
Book.bboxOf = bboxOf

local function round1(v)
    return floor(v * 10 + 0.5) / 10
end

-- A stroke's attributes besides its points: w (pen width, 1-3), kind ("hl"
-- for a marker stroke), q (width share per point, 0-255; older strokes have p,
-- 1-9).
local function withAttrs(t, s)
    t.w, t.kind = s.w, s.kind
    for _i, k in ipairs({ "p", "q" }) do
        if s[k] then
            local c = {}
            for i, v in ipairs(s[k]) do c[i] = v end
            t[k] = c
        end
    end
    return t
end
Book.withAttrs = withAttrs

-- The word at or nearest screen (x, y) in a reflowing book: { xp0, xp1, box }.
function Book:wordNear(x, y)
    local doc = self.ui.document
    local ok, w = pcall(doc.getWordFromPosition, doc, { x = x, y = y }, true)
    if ok and w and w.sbox and w.pos0 then return { xp0 = w.pos0, xp1 = w.pos1, box = w.sbox } end
    if doc.getNearestWordAndBoxFromPosition then
        ok, w = pcall(doc.getNearestWordAndBoxFromPosition, doc, { x = x, y = y })
        if ok and w and w.sbox and w.pos0 then return { xp0 = w.pos0, xp1 = w.pos1, box = w.sbox } end
    end
end

function Book:boxOf(xp0, xp1)
    local doc = self.ui.document
    local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, xp0, xp1, true)
    if ok and boxes and boxes[1] then return boxes[1] end
end

--[[--
Anchor a group of screen strokes. Sets group.a, group.strokes (stored) and
group.box (stored bbox). Returns false when the ink can't be placed.
]]
function Book:anchor(group, screen_strokes)
    local bb = bboxOf(screen_strokes)
    if not bb then return false end
    if self:paging() then
        local page, px, py, zoom = self:toPage(bb.x + bb.w / 2, bb.y + bb.h / 2)
        if not page then return false end
        local sx, sy = self:toScreen(page, 0, 0)
        if not sx then return false end
        local stored = {}
        for _i, s in ipairs(screen_strokes) do
            local t = {}
            for i = 1, #s, 2 do
                t[i] = round1((s[i] - sx) / zoom)
                t[i + 1] = round1((s[i + 1] - sy) / zoom)
            end
            stored[#stored + 1] = withAttrs(t, s)
        end
        group.a = { page = page }
        group.strokes = stored
        group.box = bboxOf(stored)
        return true
    end
    local cx, cy = bb.x + bb.w / 2, bb.y + bb.h / 2
    local w
    if bb.h < Screen:scaleBySize(24) and bb.w > 2 * bb.h then
        -- an underline: the word just above where it starts
        w = self:wordNear(bb.x + Screen:scaleBySize(6), bb.y - Screen:scaleBySize(10))
    end
    w = w or self:wordNear(cx, cy) or self:wordNear(cx, bb.y - 8) or self:wordNear(cx, bb.y + bb.h + 8)
    local ox, oy = floor(bb.x), floor(bb.y)
    local stored = {}
    for _i, s in ipairs(screen_strokes) do
        local t = {}
        for i = 1, #s, 2 do
            t[i] = s[i] - ox
            t[i + 1] = s[i + 1] - oy
        end
        stored[#stored + 1] = withAttrs(t, s)
    end
    if w and w.box then
        group.a = { xp0 = w.xp0, xp1 = w.xp1, dx = ox - w.box.x, dy = oy - w.box.y, wh = w.box.h }
    else
        local ok, xp = pcall(self.ui.document.getXPointer, self.ui.document)
        group.a = { pxp = ok and xp or nil, dx = ox, dy = oy }
    end
    group.strokes = stored
    group.box = bboxOf(stored)
    return true
end

--[[--
Anchor a group to a text selection instead of ink (Ask AI on selected text).
`sel` is ReaderHighlight's selected_text. The group gets no strokes, only a box.
]]
function Book:anchorSelection(group, sel)
    local doc = self.ui.document
    if self:paging() then
        local pboxes = sel.pboxes
        if not (pboxes and pboxes[1]) then return false end
        local page = sel.pos0 and sel.pos0.page or pboxes[1].page
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for _i, b in ipairs(pboxes) do
            if not b.page or b.page == page then
                x0, y0 = min(x0, b.x), min(y0, b.y)
                x1, y1 = max(x1, b.x + b.w), max(y1, b.y + b.h)
            end
        end
        if x0 > x1 then return false end
        group.a = { page = page }
        group.strokes = {}
        group.box = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
        return true
    end
    local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, sel.pos0, sel.pos1, true)
    if not (ok and boxes and boxes[1]) then return false end
    local first = boxes[1]
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _i, b in ipairs(boxes) do
        x0, y0 = min(x0, b.x), min(y0, b.y)
        x1, y1 = max(x1, b.x + b.w), max(y1, b.y + b.h)
    end
    group.a = { xp0 = sel.pos0, xp1 = sel.pos1, dx = 0, dy = 0, wh = first.h }
    group.strokes = {}
    group.box = { x = x0 - first.x, y = y0 - first.y, w = x1 - x0, h = y1 - y0 }
    return true
end

-- Is the group on the screen now?
function Book:onScreen(group)
    local a = group.a or {}
    if a.page then
        if not self:paging() then return false end
        for _i, p in ipairs(self:visiblePages()) do
            if p == a.page then return true end
        end
        return false
    end
    if self:paging() then return false end
    local doc = self.ui.document
    local xp = a.xp0 or a.pxp
    if not xp then return false end
    local ok, here = pcall(doc.isXPointerInCurrentPage, doc, xp)
    return ok and here
end

-- The group's origin on the screen: ox, oy, scale (stored -> screen), or nil.
function Book:origin(group)
    local a = group.a or {}
    if a.page then
        local sx, sy, zoom = self:toScreen(a.page, 0, 0)
        if not sx then return nil end
        return sx, sy, zoom
    end
    if a.xp0 then
        local box = self:boxOf(a.xp0, a.xp1)
        if not box then return nil end
        -- the ink grows and shrinks with its word (another font size)
        local s = (a.wh and a.wh > 0 and box.h > 0) and box.h / a.wh or 1
        return box.x + a.dx * s, box.y + a.dy * s, s
    end
    if a.pxp then return a.dx, a.dy, 1 end
end

-- The group's strokes and bbox on the screen now, or nil.
function Book:screenOf(group)
    if not self:onScreen(group) then return nil end
    local ox, oy, s = self:origin(group)
    if not ox then return nil end
    local out = {}
    for _i, st in ipairs(group.strokes or {}) do
        local t = {}
        for i = 1, #st, 2 do
            t[i] = floor(ox + st[i] * s + 0.5)
            t[i + 1] = floor(oy + st[i + 1] * s + 0.5)
        end
        out[#out + 1] = withAttrs(t, st)
    end
    local b = group.box
    local box = b and { x = ox + b.x * s, y = oy + b.y * s, w = b.w * s, h = b.h * s } or bboxOf(out)
    return { strokes = out, box = box, ox = ox, oy = oy, scale = s }
end

------------------------------------------------------------------------------
-- Free space
------------------------------------------------------------------------------

--[[--
An occupancy grid for placing answers near `group`, in "layout pixels" (screen
pixel scale), with a function to bring a rect in that space to the screen.

@return grid, toScreenRect(rect), target rect in grid space
]]
function Book:spaceFor(group, sc)
    local a = group.a or {}
    if a.page then return self:pageSpace(a.page) end
    -- a reflowing page: the screen as it is (taken before Ink AI paints)
    local g = self.page_bb_grid
    if not g then return nil end
    local function toScreen(r) return r end
    return { grid = g, toScreen = toScreen, origin = { x = 0, y = 0 }, key = "screen" }
end

-- What is ink on a fixed page: a small rendering of it, read once per page.
function Book:pageInk(page)
    self.page_ink = self.page_ink or {}
    local hit = self.page_ink[page]
    if hit then return hit end
    local Place = require("glossator/place")
    local doc = self.ui.document
    local okd, dims = pcall(doc.getNativePageDimensions, doc, page)
    if not (okd and dims) then return nil end
    local zr = min(1, 600 / max(dims.w, dims.h))
    local st = self.ui.view.state or {}
    local okr, tile = pcall(doc.renderPage, doc, page, nil, zr, 0, st.gamma or 1.0, st.saturation or 1.0)
    local grid
    if okr and tile and tile.bb then
        grid = Place.fromBB(tile.bb, 0, 0, tile.bb:getWidth(), tile.bb:getHeight(), 1, 1)
    else
        logger.warn("InkAI: could not render the page for placement:", tile)
        grid = Place.newGrid(floor(dims.w * zr), floor(dims.h * zr), 1)
    end
    hit = { grid = grid, zr = zr, dims = dims }
    self.page_ink[page] = hit
    return hit
end

--[[--
The blank space of a fixed page as the screen shows it now: its grid in
"layout pixels" (the screen's scale) with the page's top-left at
(pad_left, 0), widened by the blank strips beside the page when the page is
narrower than the screen (fit page), so notes can sit there too.
@return { grid, toScreen(rect), origin (screen point of grid 0,0), key, page, zoom, pad }
]]
function Book:pageSpace(page)
    local Place = require("glossator/place")
    local sx, sy, zoom = self:toScreen(page, 0, 0)
    if not sx then return nil end
    local ink = self:pageInk(page)
    if not ink then return nil end
    local W = Screen:getWidth()
    local cell = zoom / ink.zr
    local pw = ink.dims.w * zoom
    local left = max(0, floor(sx / cell))
    local right = max(0, floor((W - (sx + pw)) / cell))
    local grid = Place.copy(ink.grid)
    grid.cell = cell
    if left > 0 or right > 0 then grid = Place.widen(grid, left, right) end
    local ox = sx - left * cell
    local function toScreen(r)
        local _, sy_now = self:toScreen(page, 0, 0)
        return { x = ox + r.x, y = (sy_now or sy) + r.y, w = r.w, h = r.h }
    end
    return {
        grid = grid, toScreen = toScreen, origin = { x = ox, y = sy }, page = page,
        zoom = zoom, pad = left * cell,
        key = table.concat({ "p", page, zoom, floor(sx), W, Screen:getHeight() }, "|"),
    }
end

-- A fixed-page group's box in its page's layout pixels (see pageSpace).
function Book:layoutBox(group, space)
    local b = group.box
    if not b then return nil end
    local z = space.zoom
    return { x = space.pad + b.x * z, y = b.y * z, w = b.w * z, h = b.h * z }
end

-- For reflowing books: read the page off the screen buffer once per layout.
function Book:sampleScreen(bb)
    local Place = require("glossator/place")
    local W, H = Screen:getWidth(), Screen:getHeight()
    local cell = max(6, floor(Screen:scaleBySize(6)))
    self.page_bb_grid = Place.fromBB(bb, 0, 0, W, H, cell, cell)
end

return Book
