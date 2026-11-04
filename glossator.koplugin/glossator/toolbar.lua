--[[--
The writing toolbar: a slim strip on the edge of the page with the pen (three
widths), the marker, the eraser (whole strokes or precise), the lasso, undo,
redo, show/hide ink, Ask AI, and a button to fold it away to a small tab.

It is painted by Ink AI's view module over the page (not a separate window),
so the pen keeps writing on the page while it is open. Taps on it, with the
pen or a finger, go to `owner:toolbarAction(id, arg)`.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local ImageWidget = require("ui/widget/imagewidget")
local RenderText = require("ui/rendertext")
local _ = require("gettext")
local Paint = require("glossator/paint")
local Screen = Device.screen

local floor, max = math.floor, math.max

local ICONS = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*/[^/]*$") or ".") .. "/icons/tools/"

local Toolbar = {}
Toolbar.__index = Toolbar

local ITEMS = {
    { id = "pen", icon = "pen", tool = true },
    { id = "marker", icon = "marker", tool = true },
    { id = "eraser", icon = "eraser", tool = true },
    { id = "lasso", icon = "lasso", tool = true },
    { sep = true },
    { id = "undo", icon = "undo" },
    { id = "redo", icon = "redo" },
    { id = "ink", icon = "eye" },
    { id = "ai", icon = "ai" },
    { sep = true },
    { id = "close", icon = "close" },
}

function Toolbar.new(owner)
    return setmetatable({ owner = owner, icons = {} }, Toolbar)
end

-- "open", "tab" (folded to a small tab) or "hidden".
function Toolbar:state()
    return G_reader_settings:readSetting("inkai_toolbar") or "tab"
end

function Toolbar:setState(s)
    G_reader_settings:saveSetting("inkai_toolbar", s)
    self.options = nil
end

function Toolbar:left()
    return G_reader_settings:isTrue("inkai_toolbar_left")
end

function Toolbar:layout()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local cell = Screen:scaleBySize(46)
    local m = Screen:scaleBySize(6)
    self.cell, self.icon = cell, Screen:scaleBySize(26)
    local state = self:state()
    self.items = {}
    if state == "hidden" then
        self.rect = nil
        return
    end
    if state == "tab" then
        -- folded: a small pill in the bottom corner, beside the footer, where
        -- the page is blank
        local w, h = floor(cell * 1.5), floor(cell * 0.8)
        local x = self:left() and m or W - w - m
        local y = H - h - m
        self.rect = { x = x, y = y, w = w, h = h }
        self.items = { { id = "openbar", rect = self.rect } }
        return
    end
    local n, seps = 0, 0
    for _i, it in ipairs(ITEMS) do
        if it.sep then seps = seps + 1 else n = n + 1 end
    end
    local sep_h = Screen:scaleBySize(10)
    local h = n * cell + seps * sep_h + 2 * m
    local w = cell + 2 * m
    local x = self:left() and 0 or W - w
    local y = floor((H - h) / 2)
    self.rect = { x = x, y = y, w = w, h = h }
    local cy = y + m
    for _i, it in ipairs(ITEMS) do
        if it.sep then
            table.insert(self.items, { sep = true, y = cy + floor(sep_h / 2) })
            cy = cy + sep_h
        else
            table.insert(self.items, { id = it.id, icon = it.icon, tool = it.tool,
                rect = { x = x + m, y = cy, w = cell, h = cell } })
            cy = cy + cell
        end
    end
    -- the options of the current tool, beside the bar
    self.opt_items = nil
    local o = self.options
    if o then
        local anchor
        for _i, it in ipairs(self.items) do if it.id == o then anchor = it end end
        if anchor then
            local labels
            if o == "pen" then labels = { { arg = 1 }, { arg = 2 }, { arg = 3 } }
            elseif o == "eraser" then labels = { { arg = "stroke", text = _("Whole strokes") }, { arg = "precise", text = _("Precise") } }
            end
            if labels then
                local face = Font:getFace("cfont", 15)
                local ow = 0
                for _i, l in ipairs(labels) do
                    l.w = l.text and (RenderText:sizeUtf8Text(0, nil, face, l.text, true).x + 2 * m * 2) or cell
                    ow = ow + l.w
                end
                local ox = self:left() and (x + w + m) or (x - ow - m)
                local oy = anchor.rect.y
                self.opt_rect = { x = ox - m, y = oy - m, w = ow + 2 * m, h = cell + 2 * m }
                self.opt_items = {}
                local cx = ox
                for _i, l in ipairs(labels) do
                    table.insert(self.opt_items, { opt = o, arg = l.arg, text = l.text, face = face,
                        rect = { x = cx, y = oy, w = l.w, h = cell } })
                    cx = cx + l.w
                end
            end
        end
    end
end

-- What is at (x, y): { id } or { opt, arg }, or nil. True `inside` when (x, y)
-- is on the bar at all (a tap there never reaches the page).
function Toolbar:hit(x, y)
    local function inr(r) return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end
    for _i, it in ipairs(self.opt_items or {}) do
        if inr(it.rect) then return it, true end
    end
    if inr(self.opt_rect) then return nil, true end
    for _i, it in ipairs(self.items or {}) do
        if not it.sep and inr(it.rect) then return it, true end
    end
    return nil, inr(self.rect)
end

-- The area the bar (and its options) covers, for notes to keep clear of.
-- `columns`: the open bar's whole columns (it stays put while the page scrolls).
function Toolbar:columns()
    if self:state() ~= "open" then return {} end
    return self:covers()
end

function Toolbar:covers()
    local out = {}
    if self.rect then out[#out + 1] = self.rect end
    if self.opt_rect then out[#out + 1] = self.opt_rect end
    return out
end

function Toolbar:image(name)
    local img = self.icons[name]
    if not img then
        local ok, w = pcall(function()
            return ImageWidget:new{ file = ICONS .. name .. ".svg", width = self.icon, height = self.icon, alpha = true }
        end)
        img = ok and w or false
        self.icons[name] = img
    end
    return img or nil
end

function Toolbar:paintIcon(bb, name, r, dim)
    local img = self:image(name)
    if not img then return end
    local x = r.x + floor((r.w - self.icon) / 2)
    local y = r.y + floor((r.h - self.icon) / 2)
    img:paintTo(bb, x, y)
    if dim then bb:lightenRect(x, y, self.icon, self.icon, 0.6) end
end

function Toolbar:paint(bb, ox, oy)
    if not self.rect then return end
    local owner = self.owner
    local r = self.rect
    local rad = Screen:scaleBySize(10)
    bb:paintRoundedRect(ox + r.x, oy + r.y, r.w, r.h, Blitbuffer.COLOR_WHITE, rad)
    bb:paintBorder(ox + r.x, oy + r.y, r.w, r.h, max(1, Screen:scaleBySize(1)), Blitbuffer.COLOR_GRAY_9, rad)
    if self:state() == "tab" then
        local it = self.items[1].rect
        local half = floor(it.w / 2)
        self:paintIcon(bb, self:left() and "close" or "open", { x = ox + it.x + Screen:scaleBySize(2), y = oy + it.y, w = half, h = it.h })
        self:paintIcon(bb, "pen", { x = ox + it.x + half - Screen:scaleBySize(2), y = oy + it.y, w = half, h = it.h })
        return
    end
    for _i, it in ipairs(self.items) do
        if it.sep then
            bb:paintRect(ox + r.x + Screen:scaleBySize(12), oy + it.y, r.w - Screen:scaleBySize(24), max(1, Screen:scaleBySize(1)), Blitbuffer.COLOR_LIGHT_GRAY)
        else
            local ir = { x = ox + it.rect.x, y = oy + it.rect.y, w = it.rect.w, h = it.rect.h }
            local icon = it.icon
            local dim = false
            if it.id == "ink" and not owner:shown() then icon = "eye-off" end
            if it.id == "close" and self:left() then icon = "open" end
            if it.id == "undo" then dim = not owner:canUndo() end
            if it.id == "redo" then dim = not owner:canRedo() end
            if it.tool and owner:tool() == it.id then
                bb:paintRoundedRect(ir.x + 2, ir.y + 2, ir.w - 4, ir.h - 4, Blitbuffer.COLOR_GRAY_D, Screen:scaleBySize(8))
            end
            self:paintIcon(bb, icon, ir, dim)
            -- the pen's width, as a dot in the corner
            if it.id == "pen" then
                local d = math.ceil(Paint.radius(owner:penWidth())) + 1
                bb:paintRect(ir.x + ir.w - d * 2 - 4, ir.y + ir.h - d * 2 - 4, d * 2, d * 2, Blitbuffer.COLOR_BLACK)
            end
        end
    end
    if self.opt_items then
        local orr = self.opt_rect
        bb:paintRoundedRect(ox + orr.x, oy + orr.y, orr.w, orr.h, Blitbuffer.COLOR_WHITE, rad)
        bb:paintBorder(ox + orr.x, oy + orr.y, orr.w, orr.h, max(1, Screen:scaleBySize(1)), Blitbuffer.COLOR_GRAY_9, rad)
        for _i, it in ipairs(self.opt_items) do
            local ir = it.rect
            local sel = (it.opt == "pen" and owner:penWidth() == it.arg) or (it.opt == "eraser" and owner:eraserMode() == it.arg)
            if sel then
                bb:paintRoundedRect(ox + ir.x + 2, oy + ir.y + 2, ir.w - 4, ir.h - 4, Blitbuffer.COLOR_GRAY_D, Screen:scaleBySize(8))
            end
            if it.text then
                local m = RenderText:sizeUtf8Text(0, nil, it.face, it.text, true)
                RenderText:renderUtf8Text(bb, ox + ir.x + floor((ir.w - m.x) / 2),
                    oy + ir.y + floor((ir.h + m.y_top - m.y_bottom) / 2), it.face, it.text, true, false, Blitbuffer.COLOR_BLACK)
            else
                local rr = Paint.radius(it.arg)
                local cx, cy = ox + ir.x + floor(ir.w / 2), oy + ir.y + floor(ir.h / 2)
                Paint.segment(bb, cx - ir.w * 0.25, cy, cx + ir.w * 0.25, cy, rr, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

return Toolbar
