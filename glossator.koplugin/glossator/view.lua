--[[--
A note, opened: the conversation in the teacher's hand on a sheet of paper
(what you asked, the answer, then any follow-ups), and at the bottom a small
lined pad to write a follow-up with the pen, or type one. The answer comes
into the same card. Close it and you're back on the page, nothing locked.

A long conversation turns over in pages (no scrolling on e-ink).

The pen reaches the pad through Glossator's stylus callback (see ink.lua,
which asks `padHit`, `padDown`, `padMove` and `padUp`); outside the pad the
pen works like a finger, for the buttons.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText = require("ui/rendertext")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local _ = require("gettext")
local Paint = require("glossator/paint")
local Rich = require("glossator/rich")
local Screen = Device.screen

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local NOTE_INK = Blitbuffer.Color8(0x38)
local ASK_INK = Blitbuffer.COLOR_GRAY_7

------------------------------------------------------------------------------
-- The conversation: blocks of laid out text, shown a page at a time
------------------------------------------------------------------------------

local Sheet = Widget:extend{
    rows = nil,   -- { { L, line, color } } for this page
    width = 0, height = 0,
}

function Sheet:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Sheet:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    for _i, r in ipairs(self.rows) do
        if r.rule then
            bb:paintRect(x, y + r.y, self.width, max(1, Screen:scaleBySize(1)), Blitbuffer.COLOR_LIGHT_GRAY)
        else
            Rich.paint({ lines = { r.line } }, bb, x, y + r.y - (r.line.base - r.line.h), r.color)
        end
    end
end

------------------------------------------------------------------------------
-- The pad
------------------------------------------------------------------------------

local Pad = Widget:extend{
    width = 0, height = 0,
    strokes = nil,
    hint = nil,
}

function Pad:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Pad:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    local step = floor(self.height / 3)
    for ly = y + step, y + self.height - 2, step do
        bb:paintRect(x, ly, self.width, max(1, Screen:scaleBySize(1)), Blitbuffer.COLOR_GRAY_D)
    end
    bb:paintBorder(x, y, self.width, self.height, max(1, Screen:scaleBySize(1)), Blitbuffer.COLOR_GRAY_B, Screen:scaleBySize(6))
    if #self.strokes == 0 and self.hint then
        local f = Font:getFace("cfont", 14)
        local m = RenderText:sizeUtf8Text(0, nil, f, self.hint, true)
        RenderText:renderUtf8Text(bb, x + floor((self.width - m.x) / 2), y + floor((self.height + m.y_top) / 2),
            f, self.hint, true, false, Blitbuffer.COLOR_GRAY_9)
    end
    for _i, s in ipairs(self.strokes) do
        Paint.stroke(bb, x, y, s, true)
    end
end

-- The handwriting alone, black on white, as a PNG for Claude.
function Pad:writePNG(path)
    local bb = Blitbuffer.new(self.width, self.height, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    for _i, s in ipairs(self.strokes) do Paint.stroke(bb, 0, 0, s, true) end
    local ok, err = pcall(bb.writePNG, bb, path)
    bb:free()
    return ok, err
end

------------------------------------------------------------------------------
-- The card
------------------------------------------------------------------------------

local View = InputContainer:extend{
    group = nil,
    px = 40,
    hand = "kalam",
    transient = false,  -- an answer that isn't on the page (explain this page)
    on_ask = nil,       -- function(view, { typed = text } or { image = path })
    on_delete = nil,    -- function(with_ink)
    on_close = nil,
    on_type = nil,      -- function(): ask a typed follow-up (the card closes for it)
    pad_path = nil,
}

function View:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.card_w = floor(W * 0.86)
    self.pad_px = Size.padding.large * 2
    self.inner_w = self.card_w - 2 * self.pad_px - 2 * Size.border.window
    self.pad = Pad:new{
        width = self.inner_w,
        height = floor(H * 0.12),
        strokes = {},
        hint = _("Write a follow-up here with the pen"),
    }
    self.page = nil -- the last page, at first
    self.ges_events = {
        TapOff = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:layoutThread()
    self:build()
end

-- The conversation as rows of lines, and pages of rows that fit.
function View:layoutThread()
    local g = self.group
    local w = self.inner_w
    local rows = {}
    local function add(text, px, color)
        if not text or text == "" then return end
        local L = Rich.layout(text, { width = w, px = px, hand = self.hand, keep_newlines = true })
        for _i, ln in ipairs(L.lines) do
            rows[#rows + 1] = { line = ln, color = color, h = ln.h + ln.d + floor(px * 0.16) }
        end
    end
    local gap = Screen:scaleBySize(10)
    local function rule()
        rows[#rows + 1] = { rule = true, h = gap * 2 }
    end
    if g.question and g.question ~= "" then add(_("You:") .. " " .. g.question, self.px * 0.8, ASK_INK) end
    add(g.note .. (g.more and ("\n\n" .. g.more) or ""), self.px * 1.05, NOTE_INK)
    for _i, r in ipairs(g.replies or {}) do
        rule()
        add(_("You:") .. " " .. (r.question or "?"), self.px * 0.8, ASK_INK)
        add(r.note .. (r.more and ("\n\n" .. r.more) or ""), self.px * 1.05, NOTE_INK)
    end
    if self.pending then
        rule()
        if self.pending_q then add(_("You:") .. " " .. self.pending_q, self.px * 0.8, ASK_INK) end
        add(_("Thinking\u{2026}"), self.px * 0.9, ASK_INK)
    end
    if self.error then
        rule()
        add(self.error, self.px * 0.8, ASK_INK)
    end
    -- pages
    local H = Screen:getHeight()
    local max_h = floor(H * (self.transient and 0.66 or 0.5))
    local pages, cur, ch = {}, {}, 0
    for _i, r in ipairs(rows) do
        if ch + r.h > max_h and #cur > 0 then
            pages[#pages + 1] = { rows = cur, h = ch }
            cur, ch = {}, 0
        end
        if not (r.rule and #cur == 0) then
            r.y = ch
            cur[#cur + 1] = r
            ch = ch + r.h
        end
    end
    if #cur > 0 or #pages == 0 then pages[#pages + 1] = { rows = cur, h = ch } end
    -- place each row on its page
    for _i, p in ipairs(pages) do
        local y = 0
        for _i, r in ipairs(p.rows) do
            r.y = y + (r.rule and gap or 0)
            if not r.rule then r.y = y end
            y = y + r.h
        end
        p.h = y
    end
    self.pages = pages
    if not self.page or self.page > #pages then self.page = #pages end
end

function View:build()
    local p = self.pages[self.page]
    self.sheet = Sheet:new{ rows = p.rows, width = self.inner_w, height = max(p.h, Screen:scaleBySize(20)) }
    local nav = {}
    if #self.pages > 1 then
        table.insert(nav, { text = "\u{2039}", enabled = self.page > 1, callback = function() self:turn(-1) end })
    end
    local rows = {}
    if not self.transient then
        local first = {
            { text = _("Keyboard"), id = "keyboard", callback = function() self:typeQuestion() end },
            { text = _("Clear"), enabled = #self.pad.strokes > 0, callback = function() self:clearPad() end },
            { text = _("Ask"), enabled = #self.pad.strokes > 0 and not self.pending, callback = function() self:askWritten() end },
        }
        table.insert(rows, first)
    end
    local second = {}
    for _i, b in ipairs(nav) do table.insert(second, b) end
    if not self.transient then
        table.insert(second, { text = _("Delete"), callback = function() self:askDelete() end })
    end
    table.insert(second, { text = _("Close"), callback = function() self:close() end })
    if #self.pages > 1 then
        table.insert(second, { text = "\u{203A}", enabled = self.page < #self.pages, callback = function() self:turn(1) end })
    end
    table.insert(rows, second)
    self.buttons = ButtonTable:new{
        width = self.inner_w,
        zero_sep = true,
        show_parent = self,
        buttons = rows,
    }
    local group = VerticalGroup:new{ align = "left", self.sheet, VerticalSpan:new{ width = self.pad_px } }
    if not self.transient then
        table.insert(group, self.pad)
        table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    end
    table.insert(group, self.buttons)
    self.card = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = self.pad_px,
        group,
    }
    self[1] = self.card
    local W, H = Screen:getWidth(), Screen:getHeight()
    local size = self.card:getSize()
    self.card_dimen = Geom:new{
        x = floor((W - size.w) / 2),
        y = floor((H - size.h) / 2),
        w = size.w, h = size.h,
    }
end

function View:paintTo(bb, x, y)
    self.card:paintTo(bb, x + self.card_dimen.x, y + self.card_dimen.y)
end

function View:refresh()
    local old = self.card_dimen
    self:layoutThread()
    self:build()
    UIManager:setDirty("all", "ui", old:combine(self.card_dimen))
end

function View:turn(d)
    self.page = max(1, min(#self.pages, self.page + d))
    self:build()
    UIManager:setDirty("all", "ui")
end

function View:onSwipe(_, ges)
    if #self.pages > 1 then
        if ges.direction == "west" then self:turn(1) return true end
        if ges.direction == "east" then self:turn(-1) return true end
    end
    return true
end

function View:onTapOff(_, ges)
    if not self.card_dimen:contains(ges.pos) then self:close() end
    return true
end

------------------------------------------------------------------------------
-- Asking a follow-up
------------------------------------------------------------------------------

-- Typing: the card makes way for the question dialog and its keyboard (a
-- dialog stacked over the card left the keyboard hidden), and comes back with
-- the answer.
function View:typeQuestion()
    local on_type = self.on_type
    self:close()
    if on_type then on_type() end
end

function View:askWritten()
    if #self.pad.strokes == 0 then return end
    local ok = self.pad:writePNG(self.pad_path)
    if not ok then return end
    self:ask({ image = self.pad_path })
end

function View:ask(req)
    if self.pending then return end
    self.pending = true
    self.pending_q = req.typed
    self.error = nil
    self:refresh()
    if self.on_ask then self.on_ask(self, req) end
end

-- Called by ink.lua when the answer (or an error) arrives.
function View:answered(err)
    self.pending, self.pending_q = false, nil
    self.error = err
    if not err then self.pad.strokes = {} end
    self.page = nil
    self:refresh()
end

function View:clearPad()
    self.pad.strokes = {}
    self:refresh()
end

-- The pen on the pad (ink.lua routes it here).
function View:padHit(x, y)
    local d = self.pad.dimen
    return not self.transient and d and x >= d.x and x < d.x + d.w and y >= d.y and y < d.y + d.h
end

function View:padDown(x, y)
    local d = self.pad.dimen
    self.pad_stroke = { w = 2, x - d.x, y - d.y }
    table.insert(self.pad.strokes, self.pad_stroke)
    local r = Paint.radius(2)
    Paint.dot(Screen.bb, x, y, r, Paint.INK)
    UIManager:setDirty(nil, "fast", Geom:new{ x = floor(x - r - 2), y = floor(y - r - 2), w = floor(2 * r + 5), h = floor(2 * r + 5) })
end

function View:padMove(x, y)
    local s = self.pad_stroke
    if not s then return end
    local d = self.pad.dimen
    x = min(max(x, d.x), d.x + d.w - 1)
    y = min(max(y, d.y), d.y + d.h - 1)
    local px, py = s[#s - 1] + d.x, s[#s] + d.y
    if abs(x - px) + abs(y - py) < 1.5 then return end
    s[#s + 1], s[#s + 2] = x - d.x, y - d.y
    local r = Paint.radius(2)
    Paint.segment(Screen.bb, px, py, x, y, r, Paint.INK, r)
    UIManager:setDirty(nil, "fast", Geom:new{
        x = floor(min(px, x) - r - 2), y = floor(min(py, y) - r - 2),
        w = floor(abs(x - px) + 2 * r + 5), h = floor(abs(y - py) + 2 * r + 5) })
end

function View:padUp()
    if not self.pad_stroke then return end
    self.pad_stroke = nil
    -- the buttons that need ink (Clear, Ask) come alive
    if #self.pad.strokes == 1 then self:refresh() end
end

------------------------------------------------------------------------------

function View:askDelete()
    local dialog
    local has_ink = #(self.group.strokes or {}) > 0
    local buttons = {
        {{ text = _("Delete the note"), callback = function()
            UIManager:close(dialog)
            self:close()
            if self.on_delete then self.on_delete(false) end
        end }},
    }
    if has_ink then
        table.insert(buttons, {{ text = _("Delete the note and my ink"), callback = function()
            UIManager:close(dialog)
            self:close()
            if self.on_delete then self.on_delete(true) end
        end }})
    end
    table.insert(buttons, {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }})
    dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(dialog)
end

function View:onShow()
    UIManager:setDirty(self, "ui", self.card_dimen)
end

function View:close()
    UIManager:close(self, "ui")
end

function View:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.card_dimen)
    if self.on_close then self.on_close(self) end
end

return View
