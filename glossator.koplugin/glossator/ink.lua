--[[--
Glossator's ink and AI: write and circle on the book page with the pen, tap "Ask AI", and
Claude's answer appears in the margin next to your ink, in a teacher's
handwriting, with real math.

  * The pen always writes on the page while a book is open (no mode to
    enter). Fingers still turn pages, open menus and select text.
  * A writing toolbar on the edge: pen (three widths), marker (it becomes a
    real KOReader highlight), eraser (whole strokes or precise), lasso,
    undo/redo, show/hide ink, Ask AI. It folds away to a small tab.
  * After writing, a small "Ask AI" chip appears next to the fresh ink. Tap
    it to ask; tap elsewhere or wait a few seconds and the ink stays as a
    plain annotation. Selected text has "Ask AI" in its popup too.
  * Answers are placed in the nearest blank space (margins, gaps, the blank
    strips beside a whole page), never over the text. Tap one to expand it,
    ask a follow-up or delete it.
  * Ink and answers are kept with the book, anchored to the page (PDF) or
    to the nearest word (EPUB).

Setup: put your Anthropic API key (one line) in koreader/glossator_key.txt
(koreader/inkai_key.txt, from Ink AI, works too).
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local json = require("json")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local T = ffiutil.template
local _ = require("gettext")

local Book = require("glossator/book")
local Claude = require("glossator/claude")
local Edit = require("glossator/edit")
local Fonts = require("glossator/fonts")
local Math = require("glossator/math")
local Paint = require("glossator/paint")
local PenBridge = require("glossator/penbridge")
local ExportHook = require("glossator/exporthook")
local Place = require("glossator/place")
local Rich = require("glossator/rich")
local Stylus = require("glossator/stylus")
local Toolbar = require("glossator/toolbar")
local Screen = Device.screen

local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt

local SETTING = "glossator_ink"        -- per book: { v = 2, groups = { ... } }
local OLD_SETTING = "inkai_ink"        -- the same, as Ink AI (the plugin's old name) kept it
-- The models in the menu: Claude with an Anthropic key, and through OpenRouter
-- (an OpenRouter key) a smart and a fast one from each big provider. All read
-- images. "More models" in the menu fetches OpenRouter's newest.
local MODELS = {
    { id = "claude-opus-5-5", label = "Claude Opus 5.5 · smartest" },
    { id = "claude-sonnet-5-5", label = "Claude Sonnet 5.5 · balanced" },
    { id = "claude-haiku-5-5", label = "Claude Haiku 5.5 · fast" },
    { id = "openrouter:google/gemini-4-argon", label = "Gemini 4 Argon · smartest (Google)", openrouter = true },
    { id = "openrouter:google/gemini-3.8-flash", label = "Gemini 3.8 Flash · fast (Google)", openrouter = true },
    { id = "openrouter:openai/gpt-6-astra", label = "GPT-6 Astra · smartest (OpenAI)", openrouter = true },
    { id = "openrouter:openai/gpt-6.1-sol", label = "GPT-6.1 Sol · balanced (OpenAI)", openrouter = true },
    { id = "openrouter:openai/gpt-6-luna", label = "GPT-6 Luna · fast (OpenAI)", openrouter = true },
    { id = "openrouter:x-ai/grok-4.7", label = "Grok 4.7 (xAI)", openrouter = true },
    { id = "openrouter:mistralai/mistral-large-4-0", label = "Mistral Large 4 (Mistral)", openrouter = true },
    { id = "openrouter:qwen/qwen3.8-flash", label = "Qwen3.8 Flash · fast, low cost (Alibaba)", openrouter = true },
}
-- Claude's ids on OpenRouter, for a reader with only an OpenRouter key.
local CLAUDE_ON_OPENROUTER = {
    ["claude-opus-5-5"] = "anthropic/claude-opus-5.5",
    ["claude-sonnet-5-5"] = "anthropic/claude-sonnet-5.5",
    ["claude-haiku-5-5"] = "anthropic/claude-haiku-5.5",
}
local SIZES = { small = 9.5, medium = 11, large = 13 } -- note size, in points
local CHIP_DELAY = 1.6    -- s after the pen lifts before the chip shows (more if it hovers)
local CHIP_HOVER = 0.8    -- the pen hovered this recently: you're still writing, wait
local CHIP_MAX_WAIT = 8   -- but no longer than this after the last stroke
local CHIP_LINGER = 10    -- s of quiet before the chip goes away
local GROUP_SEC = 4       -- strokes this close in time (and space) are one question
local NOTE_INK = Blitbuffer.Color8(0x38) -- the teacher's dark grey
local THREAD_MAX = 6
local IMAGE_MAX = 1568    -- longest side of the page image sent to Claude
local LIVE_MS = 20        -- live ink: at most one refresh this often (Ink Away's pace for the Scribe)
local LIVE_TAIL = 0.035   -- s: the last samples of a burst follow within this

local function contains(r, x, y)
    return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

local function grow(r, d)
    return { x = r.x - d, y = r.y - d, w = r.w + 2 * d, h = r.h + 2 * d }
end

local function rectGap(a, b)
    local dx = max(b.x - (a.x + a.w), a.x - (b.x + b.w), 0)
    local dy = max(b.y - (a.y + a.h), a.y - (b.y + b.h), 0)
    return sqrt(dx * dx + dy * dy)
end

local function union(a, b)
    if not a then return b end
    if not b then return a end
    local x0, y0 = min(a.x, b.x), min(a.y, b.y)
    return { x = x0, y = y0, w = max(a.x + a.w, b.x + b.w) - x0, h = max(a.y + a.h, b.y + b.h) - y0 }
end

-- A timer's callback that can't take the reader down: KOReader catches nothing
-- that goes wrong in a scheduled task.
local function guarded(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then logger.err("Glossator:", err) end
    end
end

local function newId()
    return tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
end

local Ink = WidgetContainer:extend{
    name = "glossator_ink",
}

function Ink:init()
    local dir = DataStorage:getDataDir()
    self.key_path = dir .. "/glossator_key.txt"
    self.old_key_path = dir .. "/inkai_key.txt"
    self.or_key_path = dir .. "/glossator_openrouter_key.txt"
    self.mock_path = dir .. "/glossator_mock.txt"
    self.old_mock_path = dir .. "/inkai_mock.txt"
    self.page_path = dir .. "/glossator_page.png"
    self.crop_path = dir .. "/glossator_closeup.png"
    self.pad_path = dir .. "/glossator_followup.png"
    self.log_path = dir .. "/glossator_log.md"
    self.export_dir = dir .. "/glossator_exports"
    self.book = Book.new(self.ui)
    self.data = self.ui.doc_settings:readSetting(SETTING) or self.ui.doc_settings:readSetting(OLD_SETTING)
    if type(self.data) ~= "table" or type(self.data.groups) ~= "table" then
        self.data = { v = 2, groups = {} }
    end
    for _i, g in ipairs(self.data.groups) do
        if g.status == "asking" then g.status = nil end -- interrupted last time
    end
    self.fresh_live = setmetatable({}, { __mode = "k" }) -- per group, not saved: screen strokes while fresh
    self.rev = 0
    self.note_rev = 0 -- notes are placed again only when notes change, not with every stroke
    self.cache = {}
    self.place_cache = {}
    self.history = Edit.History.new()
    self.toolbar = Toolbar.new(self)
    self.pen = Stylus.new()
    self.stylus_cb = function(inp, slot) return self:stylusFrame(inp, slot) end
    self.ui.view:registerViewModule("inkai", {
        paintTo = function(_, bb, x, y) self:paint(bb, x, y) end,
    })
    self:onDispatcherRegisterActions()
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self.ui.highlight:addToHighlightDialog("12_inkai_ask", function(hl)
            return {
                text = _("Ask AI"),
                callback = function() self:askSelection(hl) end,
            }
        end)
    end
end

------------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------------

function Ink:penOn()
    return G_reader_settings:readSetting("inkai_pen") ~= false
end

function Ink:shown()
    return G_reader_settings:readSetting("inkai_show") ~= false
end

function Ink:getModel()
    return G_reader_settings:readSetting("inkai_model") or MODELS[1].id
end

function Ink:hand()
    return G_reader_settings:readSetting("inkai_hand") or "kalam"
end

function Ink:noteSize()
    return G_reader_settings:readSetting("inkai_size") or "medium"
end

function Ink:notePx()
    local pt = SIZES[self:noteSize()] or SIZES.medium
    local dpi = Screen:getDPI() or 300
    return floor(pt * dpi / 72 + 0.5)
end

-- The tool the pen writes with: "pen", "marker", "eraser" or "lasso".
function Ink:tool()
    return G_reader_settings:readSetting("inkai_tool") or "pen"
end

function Ink:penWidth()
    return G_reader_settings:readSetting("inkai_pen_width") or 2
end

function Ink:eraserMode()
    return G_reader_settings:readSetting("inkai_eraser") or "stroke"
end

function Ink:canUndo() return self.history:canUndo() end
function Ink:canRedo() return self.history:canRedo() end

function Ink:readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- The keys in koreader/glossator_key.txt (and the older inkai_key.txt): one
-- per line, told apart by their start: sk-or-... is OpenRouter's, any other is
-- Anthropic's.
function Ink:readKeys()
    local keys = {}
    for _i, path in ipairs({ self.key_path, self.or_key_path, self.old_key_path }) do
        local s = self:readFile(path)
        if s then
            for line in s:gmatch("[^\r\n]+") do
                local k = line:gsub("%s", "")
                if k:match("^sk%-or%-") then keys.openrouter = keys.openrouter or k
                elseif k ~= "" and not k:match("^#") then keys.anthropic = keys.anthropic or k end
            end
        end
    end
    return keys
end

function Ink:readApiKey()
    local keys = self:readKeys()
    return keys.anthropic or keys.openrouter
end

-- A short name for the model in use.
function Ink:modelLabel(id)
    id = id or self:getModel()
    for _i, m in ipairs(MODELS) do
        if m.id == id then return m.label end
    end
    for _i, m in ipairs(G_reader_settings:readSetting("glossator_more_models") or {}) do
        if "openrouter:" .. m.id == id then return m.name end
    end
    return (id:gsub("^openrouter:", ""))
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

-- Are you writing? The pen is on the page or just lifted, or it hovers
-- while you've been writing. Then a touch on the page is your hand, not a tap.
function Ink:writingActive()
    if self.stroke or self.pen_hold or self.pen_tap then return true end
    local now = time.now()
    -- a hand the panel reported as a palm, just now
    if self.palm_at and time.to_s(now - self.palm_at) < 0.5 then return true end
    local lift = self.last_lift and time.to_s(now - self.last_lift)
    if lift and lift < 1.2 then return true end
    -- the pen hovering over the glass, a little while after writing
    if lift and lift < 8 then
        if self:penInRange() then return true end
        local near = self.pen_near and time.to_s(now - self.pen_near)
        if near and near < 0.6 then return true end
    end
    return false
end

-- Is the pen over the screen (hovering or touching)? On a Wacom pen KOReader
-- keeps the pen's tool on its slot from when it comes into range until it
-- leaves (after Ink Away).
function Ink:penInRange()
    local inp = Device.input
    if not (inp and inp.wacom_protocol and inp.pen_slot and inp.ev_slots) then return false end
    local p = inp.ev_slots[inp.pen_slot]
    return p ~= nil and (p.tool == Stylus.TOOL_PEN or p.tool == Stylus.TOOL_ERASER)
end

-- The pen's pressure (0..255) when "Pen pressure" is on and the pen reports
-- one; nil otherwise (the width then follows the writing speed).
function Ink:pressureOf(slot, inp)
    if not G_reader_settings:isTrue("glossator_pressure") then return nil end
    return Paint.fromRaw(slot and slot.pressure, inp and inp.pressure_max or 4095)
end

-- Finger gestures on the page while writing are the hand resting on the glass
-- (a wrist, a palm): swallowed, so they don't turn the page. The pen's own taps
-- (sent by us, marked `pen`) go through. Installed on the reader itself, so it
-- covers every gesture: taps, swipes, holds, pans, other plugins' gestures.
function Ink:installPalmGuard()
    local ui = self.ui
    if self.palm_guard then return end
    local own = rawget(ui, "onGesture")
    local base = own or ui.onGesture
    self.palm_guard = function(this, ges, ...)
        if ges and not ges.pen and G_reader_settings:readSetting("glossator_palm") ~= false then
            local ok, active = pcall(self.writingActive, self)
            -- a deliberate tap on the toolbar or the chip still works
            if ok and active and not (ges.ges == "tap" and ges.pos and self:onOwnControl(ges.pos.x, ges.pos.y)) then
                return true
            end
        end
        return base(this, ges, ...)
    end
    self.palm_guard_prev = own
    ui.onGesture = self.palm_guard
end

-- Whether (x, y) is on the writing toolbar (or its open options) or the chip.
function Ink:onOwnControl(x, y)
    if self.toolbar.rect then
        local it, inside = self.toolbar:hit(x, y)
        if it or inside or self.toolbar.options then return true end
    end
    return self.chip ~= nil and contains(self.chip.rect, x, y)
end

function Ink:removePalmGuard()
    if self.palm_guard and rawget(self.ui, "onGesture") == self.palm_guard then
        self.ui.onGesture = self.palm_guard_prev
    end
    self.palm_guard = nil
end

function Ink:onReaderReady()
    self.ui:registerTouchZones({{
        id = "inkai_tap",
        ges = "tap",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        overrides = {
            "tap_forward", "tap_backward", "readerhighlight_tap", "readerlink_tap",
            "readermenu_tap", "readermenu_ext_tap", "readerconfigmenu_tap", "readerconfigmenu_ext_tap",
            "readerfooter_tap", "kindleui_top", "kindleui_bottom", "kindleui_turn",
        },
        handler = function(ges) return self:onTap(ges) end,
    }})
    self:attachPen()
    self:installPalmGuard()
    -- AI notes in KOReader's Export highlights (Readwise, Joplin, Markdown…)
    if self.ui.document and self.ui.document.file then ExportHook.live[self.ui.document.file] = self end
    pcall(ExportHook.install)
end

function Ink:onCloseDocument()
    self:detachPen()
    self:removePalmGuard()
    if self.ui.document and ExportHook.live[self.ui.document.file] == self then
        ExportHook.live[self.ui.document.file] = nil
    end
    self:hideChip(true)
    if self.job then
        pcall(ffiutil.terminateSubProcess, self.job.pid)
        self.job = nil
    end
end

function Ink:onCloseWidget()
    self:detachPen()
end

function Ink:onSuspend()
    self:endStroke()
end

-- The page moved: the fresh ink is no longer fresh.
function Ink:onPageUpdate()
    self:pageMoved()
end
function Ink:onPosUpdate()
    self:pageMoved()
end

function Ink:pageMoved()
    self.fresh = nil
    self.sel = nil
    if self.chip and not (self.chip.group and self.chip.group.status == "asking") then
        self:hideChip(true)
    end
end

function Ink:onSetDimensions()
    self.cache = {}
    self.place_cache = {}
    self.book.page_ink = nil
end
Ink.onScreenResize = Ink.onSetDimensions

function Ink:save()
    self.ui.doc_settings:saveSetting(SETTING, self.data)
    self.rev = self.rev + 1
end

function Ink:repaint(rect)
    UIManager:setDirty(self.ui, "ui", rect and Geom:new{ x = floor(rect.x), y = floor(rect.y), w = math.ceil(rect.w), h = math.ceil(rect.h) })
end

------------------------------------------------------------------------------
-- Undo
------------------------------------------------------------------------------

-- The groups an edit on the screen can touch.
function Ink:groupsOnScreen()
    local out = {}
    for _i, g in ipairs(self.data.groups) do
        if self:screenOf(g) then out[#out + 1] = g end
    end
    return out
end

-- Run `fn` as one undoable edit of what is on the screen.
-- Run `fn` as one undoable edit. `groups`: the groups it can touch (copied for
-- undo); by default all on the screen. Groups `fn` adds are recorded too.
function Ink:edit(fn, groups)
    groups = groups or self:groupsOnScreen()
    local token = self.history:begin(groups)
    local existed = {}
    for _i, g in ipairs(self.data.groups) do existed[g] = true end
    fn()
    local present = {}
    for _i, g in ipairs(self.data.groups) do present[g] = true end
    local after = {}
    for _i, g in ipairs(groups) do
        if present[g] then after[#after + 1] = g end
    end
    for _i, g in ipairs(self.data.groups) do
        if not existed[g] then after[#after + 1] = g end
    end
    self.history:commit(token, after)
    self:save()
end

function Ink:notesChanged()
    self.note_rev = self.note_rev + 1
end

function Ink:undo()
    if self.history:doUndo(self.data.groups) then
        self:notesChanged()
        self.fresh, self.sel = nil, nil
        self:hideChip(false)
        self:save()
        self:repaint()
    end
end

function Ink:redo()
    if self.history:doRedo(self.data.groups) then
        self:notesChanged()
        self.fresh, self.sel = nil, nil
        self:hideChip(false)
        self:save()
        self:repaint()
    end
end

------------------------------------------------------------------------------
-- The pen
------------------------------------------------------------------------------

function Ink:attachPen()
    local inp = Device.input
    if self.attached or not (inp and type(inp.registerStylusCallback) == "function") then return end
    local cur = inp.stylus_callback
    self.prev_cb = cur ~= self.stylus_cb and cur or nil
    inp:registerStylusCallback(self.stylus_cb)
    self.attached = true
    -- Ink Away's pen bridge keeps the pen's events on its own slot. Without it
    -- a palm resting on the Scribe's glass moves KOReader's slot cursor: the
    -- pen's lift is lost and the next stroke is joined to the last by a long
    -- straight line. (It installs only over KOReader's own handlers, so with Ink
    -- Away's bridge already in place it steps aside.)
    if G_reader_settings:readSetting("glossator_bridge") ~= false then
        local ok, h = pcall(PenBridge.install, inp)
        self.bridge = ok and h or nil
        if not ok then logger.warn("Glossator: pen bridge:", h) end
    end
end

function Ink:detachPen()
    if not self.attached then return end
    self.attached = false
    self:endStroke()
    if self.bridge then pcall(PenBridge.uninstall, self.bridge) end
    self.bridge = nil
    local inp = Device.input
    if inp and inp.stylus_callback == self.stylus_cb then
        if self.prev_cb then inp:registerStylusCallback(self.prev_cb) else inp:unregisterStylusCallback() end
    end
    self.prev_cb = nil
end

-- Is the page itself on top (no menu or dialog over it)? Notices that close
-- by themselves are looked past.
function Ink:pageOnTop()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w and not w.invisible and not w.toast and not w.timeout then return w == self.ui end
    end
    return false
end

-- Hand the frame to whatever had the pen before us (another plugin), or to
-- KOReader as a touch.
function Ink:passOn(inp, slot)
    if self.prev_cb then
        local ok, r = pcall(self.prev_cb, inp, slot)
        if ok then return r end
    end
    return false
end

-- A stylus frame. Return true to keep it from KOReader's gesture detector.
function Ink:stylusFrame(inp, slot)
    local ok, taken = pcall(self.frame, self, inp, slot)
    if not ok then
        logger.warn("Glossator: pen:", taken)
        self.stroke, self.pen_tap = nil, nil
        return false
    end
    return taken
end

-- The pen while a note is open: on its pad it writes the follow-up, anywhere
-- else it works like a finger (the buttons). Decided when it touches down.
function Ink:padFrame(v, inp, slot)
    local facts = Stylus.facts(inp, self.learned_slot, false)
    local role = Stylus.classify(slot, facts)
    if role == Stylus.ROLE_TOUCH then return self:passOn(inp, slot) end
    if role == Stylus.ROLE_PALM then return true end
    local id = role == Stylus.ROLE_PEN_OUT and -1 or slot.id
    local step = Stylus.step(self.pen, id)
    local x, y
    if slot.x and slot.y then x, y = Stylus.screenXY(slot, Screen) end
    if step == "down" then
        if x and v:padHit(x, y) then
            self.pad_mode = "pad"
            v:padDown(x, y)
            return true
        end
        self.pad_mode = "pass"
        return false
    elseif step == "move" then
        if self.pad_mode == "pad" then
            if x then v:padMove(x, y) end
            return true
        end
        return false
    elseif step == "up" then
        local mode = self.pad_mode
        self.pad_mode = nil
        if mode == "pad" then
            v:padUp()
            return true
        end
        return false
    end
    return role == Stylus.ROLE_PEN_OUT
end

function Ink:frame(inp, slot)
    -- an open note's pad takes the pen
    local v = self.open_view
    if v and not self.stroke and UIManager:getTopmostVisibleWidget() == v then
        return self:padFrame(v, inp, slot)
    end
    -- a stroke of ours in progress keeps its frames
    local busy = self.stroke or self.pen_tap or self.pen_hold
    if not busy then
        if not self:penOn() or not self:pageOnTop() then
            if self:passOn(inp, slot) then return true end
            -- a hand the panel flags as a palm never taps anything, over a
            -- dialog or the keyboard either (a stray tap closes the keyboard)
            local role = Stylus.classify(slot, Stylus.facts(inp, self.learned_slot, false))
            if role == Stylus.ROLE_PALM then
                self.palm_at = time.now()
                return true
            end
            return false
        end
    end
    local facts = Stylus.facts(inp, self.learned_slot, false)
    local role = Stylus.classify(slot, facts)
    if role == Stylus.ROLE_PEN and slot.tool == Stylus.TOOL_PEN and slot.slot ~= nil then
        self.learned_slot = slot.slot
    end
    -- One slot owns a stroke until it lifts; another pen-like contact meanwhile
    -- is a hand (two slots feeding one stroke draw lines between them).
    local sn = slot.slot or 0
    local is_pen_slot = (inp and inp.pen_slot ~= nil and sn == inp.pen_slot)
        or (self.learned_slot ~= nil and sn == self.learned_slot)
    if role == Stylus.ROLE_PEN and self.pen_owner ~= nil and sn ~= self.pen_owner and not is_pen_slot then
        role = Stylus.ROLE_PALM
    end
    if role == Stylus.ROLE_TOUCH then return self:passOn(inp, slot) end
    if role == Stylus.ROLE_PALM then
        self.palm_at = time.now() -- a hand on the glass: fingers stay ignored
        return true
    end
    if role == Stylus.ROLE_PEN_OUT then
        self.pen_near = nil -- the pen left the screen: you've stopped writing
        if Stylus.step(self.pen, -1) == "up" then self:penUp() end
        self.pen_owner = nil
        return true
    end
    -- the pen's side button and eraser end: another plugin (Ink Away) may want
    -- them; if not, the side button is the marker and the eraser end erases
    local action = Stylus.penAction(slot, facts)
    local tool = self:tool()
    if not busy and action ~= Stylus.ACT_DRAW then
        if self.prev_cb and self:passOn(inp, slot) then return true end
        if action == Stylus.ACT_ERASER_END then tool = "eraser"
        elseif action == Stylus.ACT_BUTTON1 or action == Stylus.ACT_BUTTON2 then tool = "marker" end
    end
    local step = Stylus.step(self.pen, slot.id)
    if step == "down" then self.pen_owner = sn elseif step == "up" then self.pen_owner = nil end
    if step == nil then
        self.pen_near = time.now() -- in the air over the screen: about to write more
    end
    if step == "down" then
        if slot.x and slot.y then
            local x, y = Stylus.screenXY(slot, Screen)
            self:penDown(x, y, tool, self:pressureOf(slot, inp))
        end
    elseif step == "move" then
        if slot.x and slot.y then
            local x, y = Stylus.screenXY(slot, Screen)
            self:penMove(x, y, slot, self:pressureOf(slot, inp))
        end
    elseif step == "up" then
        self:penUp()
    end
    return true
end

-- What a pen tap at (x, y) would hit: the toolbar, the chip, a note, the selection.
function Ink:tapTarget(x, y)
    if self.toolbar.rect then
        local _h, inside = self.toolbar:hit(x, y)
        if inside then return true end
    end
    if self.chip and contains(self.chip.rect, x, y) then return true end
    if self:answerAt(x, y) then return true end
    return false
end

function Ink:penDown(x, y, tool, pressure)
    UIManager:unschedule(self.show_chip_cb)
    if tool ~= "eraser" and self:tapTarget(x, y) then
        self.pen_tap = { x = x, y = y, tool = tool }
        return
    end
    -- the pen inside the lasso's selection drags it
    if self.sel and contains(self.sel.box, x, y) and tool ~= "eraser" then
        self.stroke = { kind = "move", x, y }
        return
    end
    if self.sel then self:clearSelection() end
    -- writing again: the chip for the ink so far makes way, and comes back
    -- once you pause
    local c = self.chip
    if c and not c.selection and c.group == self.fresh and c.group.status ~= "asking" then
        -- (no repaint now: that would hold up the stroke; it goes when you pause)
        self:settleLater(grow(c.rect, 2))
        self:hideChip(false)
    end
    if self.settle_cb then UIManager:unschedule(self.settle_cb) end
    self:beginStroke(x, y, tool, pressure)
end

-- Hand KOReader a gesture at (x, y), as if a finger had made it: a quick pen
-- tap turns the page or presses a button, a pen long-press selects a word.
function Ink:sendGesture(kind, x, y)
    local Event = require("ui/event")
    local ges = { ges = kind, pos = Geom:new{ x = floor(x), y = floor(y), w = 0, h = 0 }, time = time.now(), pen = true }
    UIManager:nextTick(guarded(function() UIManager:sendEvent(Event:new("Gesture", ges)) end))
end

function Ink:penTapsAct()
    return G_reader_settings:readSetting("inkai_pen_taps") ~= false
end

function Ink:beginStroke(x, y, tool, pressure)
    local s = { tool = tool, x, y, t0 = time.now() }
    -- a pen held still on the page is a long-press: select text, as a finger does
    if (tool == "pen" or tool == "marker") and self:penTapsAct() then
        self.hold_cb = self.hold_cb or guarded(function() self:checkPenHold() end)
        UIManager:unschedule(self.hold_cb)
        UIManager:scheduleIn(0.65, self.hold_cb)
    end
    if tool == "pen" then
        s.w = self:penWidth()
        -- how much of the full width each point has: the pen's pressure when it
        -- reports one, otherwise simulated from the speed (fast is thinner)
        s.q = { pressure or 255 }
        s.real_pressure = pressure ~= nil
        s.len = 0
        s.lr = Paint.liveRadius(s)
    elseif tool == "marker" then
        s.kind = "hl"
        s.cols = {}
    end
    self.stroke = s
    self.kin, self.last_ms = {}, nil
    Stylus.acceptMove(self.kin, x, y, nil, 1)
    self:liveSegment(x, y, x, y)
end

function Ink:penMove(x, y, slot, pressure)
    if self.pen_tap then
        if abs(x - self.pen_tap.x) + abs(y - self.pen_tap.y) > Screen:scaleBySize(16) then
            -- not a tap after all: start writing from here (unless it began on the toolbar)
            local t = self.pen_tap
            self.pen_tap = nil
            if self.toolbar.rect and select(2, self.toolbar:hit(t.x, t.y)) then return end
            self:beginStroke(t.x, t.y, t.tool, pressure)
        else
            return
        end
    end
    if self.pen_hold then
        self:sendGesture("hold_pan", x, y)
        return
    end
    local s = self.stroke
    if not s then return end
    if s.kind == "move" then
        s[3], s[4] = x, y
        self:liveMoveBox()
        return
    end
    -- drop a palm's coordinates written into the pen's slot (a nib can't teleport)
    local ms = Stylus.timevMs(slot and slot.timev)
    local dt = (ms and self.last_ms and ms >= self.last_ms) and (ms - self.last_ms) or nil
    self.last_ms = ms
    local keep, restart = Stylus.acceptMove(self.kin, x, y, dt, Screen:scaleBySize(100) / 100)
    if not keep then return end
    if restart then
        local tool = s.tool
        self:endStroke()
        self:beginStroke(x, y, tool, pressure)
        return
    end
    local n = #s
    local px, py = s[n - 1], s[n]
    if abs(x - px) + abs(y - py) < 1.5 then return end
    s[n + 1], s[n + 2] = x, y
    if s.q then
        local dist = sqrt((x - px) ^ 2 + (y - py) ^ 2)
        local dist_mm = dist / Paint.pxmm()
        local q
        if s.real_pressure and pressure then q = pressure
        else q = Paint.fromSpeed(dist_mm / max(dt or 8, 1)) end
        s.q[#s.q + 1] = Paint.easeQ(s.q[#s.q], q, dist_mm)
        s.len = (s.len or 0) + dist
    end
    self:liveSegment(px, py, x, y)
end

-- The pen has rested still since it touched down: it's a long-press.
function Ink:checkPenHold()
    local s = self.stroke
    if not (s and (s.tool == "pen" or s.tool == "marker")) then return end
    local box = Book.bboxOf({ s })
    if not box or box.w > Screen:scaleBySize(10) or box.h > Screen:scaleBySize(10) then return end
    self.stroke = nil
    self:liveFlush()
    self:repaint(grow(box, Screen:scaleBySize(12))) -- the dot goes
    self.pen_hold = { x = s[1], y = s[2] }
    self:sendGesture("hold", s[1], s[2])
end

-- Is this finished stroke really a tap (short, tiny, and not part of writing)?
function Ink:isTap(s)
    if not self:penTapsAct() or not (s.tool == "pen" or s.tool == "marker") or not s.t0 then return false end
    local box = Book.bboxOf({ s })
    if not box or box.w > Screen:scaleBySize(10) or box.h > Screen:scaleBySize(10) then return false end
    if time.to_s(time.now() - s.t0) > 0.35 then return false end
    -- a dot right after writing, within about a centimetre of it, is ink (the
    -- dot of an i, a full stop); further away it is a tap
    local last = self.last_ink
    if last and time.to_s(s.t0 - last.t) < 1.5 and rectGap(box, last.box) < 12 * Paint.pxmm() then
        return false
    end
    return true
end

function Ink:penUp()
    if self.hold_cb then UIManager:unschedule(self.hold_cb) end
    if self.pen_hold then
        local h = self.pen_hold
        self.pen_hold = nil
        self:sendGesture("hold_release", h.x, h.y)
        return
    end
    if self.pen_tap then
        local t = self.pen_tap
        self.pen_tap = nil
        self:sendGesture("tap", t.x, t.y)
        return
    end
    self:endStroke()
end

-- Draw the newest piece of the stroke straight onto the screen.
function Ink:liveSegment(x0, y0, x1, y1)
    local s = self.stroke
    if not s then return end
    local r
    if s.tool == "pen" then
        local r0 = s.lr or Paint.liveRadius(s)
        local r1 = Paint.liveRadius(s)
        s.lr = r1
        Paint.segment(Screen.bb, x0, y0, x1, y1, r0, Paint.inkColor(), r1)
        r = math.ceil(max(r0, r1)) + 1
    elseif s.tool == "marker" then
        r = Paint.markerRadius()
        Paint.markerSegment(Screen.bb, x0, y0, x1, y1, r, s.cols)
    elseif s.tool == "lasso" then
        r = 2
        Paint.dotted(Screen.bb, { x0, y0, x1, y1 }, Blitbuffer.COLOR_GRAY_4)
    else -- eraser: a faint trail
        r = 2
        Paint.dotted(Screen.bb, { x0, y0, x1, y1 }, Blitbuffer.COLOR_GRAY_9)
    end
    self:liveDirty({ x = min(x0, x1) - r - 2, y = min(y0, y1) - r - 2, w = abs(x1 - x0) + 2 * r + 5, h = abs(y1 - y0) + 2 * r + 5 })
end

-- Refresh live ink at a bounded pace: rects join the pending one, which is
-- sent at most every LIVE_MS (a refresh per pen sample overwhelms the
-- Scribe's display controller and makes ink lag behind the nib).
function Ink:liveDirty(r)
    self.live_pend = union(self.live_pend, r)
    local now = time.now()
    if not self.live_last or time.to_ms(now - self.live_last) >= LIVE_MS then
        self:liveFlush()
    elseif not self.live_armed then
        self.live_armed = true
        self.live_flush_cb = self.live_flush_cb or guarded(function() self:liveFlush() end)
        UIManager:scheduleIn(LIVE_TAIL, self.live_flush_cb)
    end
end

function Ink:liveFlush()
    if self.live_armed then
        UIManager:unschedule(self.live_flush_cb)
        self.live_armed = false
    end
    local p = self.live_pend
    self.live_pend = nil
    if not p then return end
    self.live_last = time.now()
    UIManager:setDirty(nil, "fast", Geom:new{ x = floor(p.x), y = floor(p.y), w = math.ceil(p.w), h = math.ceil(p.h) })
end

function Ink:endStroke()
    local s = self.stroke
    self.stroke = nil
    if self.hold_cb then UIManager:unschedule(self.hold_cb) end
    self:liveFlush()
    if not s or #s < 2 then return end
    if s.kind == "move" then
        self:finishMove(s)
        return
    end
    if self:isTap(s) then
        local box = Book.bboxOf({ s })
        self:repaint(grow(box, Screen:scaleBySize(12))) -- the dot goes
        self:sendGesture("tap", s[1], s[2])
        return
    end
    self.last_lift = time.now()
    if s.tool == "pen" or s.tool == "marker" then
        self.last_ink = { t = time.now(), box = Book.bboxOf({ s }) }
    end
    local pts = { w = s.w, kind = s.kind, q = s.q }
    for i = 1, #s do pts[i] = s[i] end
    local box = Book.bboxOf({ pts })
    if s.tool == "eraser" then
        self:eraseAlong(pts)
    elseif s.tool == "lasso" then
        self:lassoDone(pts)
    elseif s.tool == "marker" then
        self:markerDone(pts)
    else
        self:addStroke(pts)
        -- the smoothed, tapered stroke replaces the live one once you pause
        -- (repainting the page at every lift held up the next stroke)
        if box then self:settleLater(grow(box, Paint.radius(s.w) * 2 + 4)) end
    end
end

-- Repaint what writing left behind (smoothed strokes, a chip that made way)
-- once the pen has rested, in one go.
function Ink:settleLater(rect)
    self.settle_rect = union(self.settle_rect, rect)
    self.settle_cb = self.settle_cb or guarded(function() self:settle() end)
    UIManager:unschedule(self.settle_cb)
    UIManager:scheduleIn(1.0, self.settle_cb)
end

function Ink:settle()
    if self.settle_cb then UIManager:unschedule(self.settle_cb) end
    if self.stroke then
        UIManager:scheduleIn(0.5, self.settle_cb)
        return
    end
    local r = self.settle_rect
    self.settle_rect = nil
    if r then self:repaint(r) end
end

-- Add a finished stroke (screen points) to the fresh group, or start one.
function Ink:addStroke(pts)
    local now = time.now()
    local sbox = Book.bboxOf({ pts })
    local g = self.fresh
    local lv = g and self.fresh_live[g]
    if g then
        local d = lv and rectGap(sbox, lv.box) or math.huge
        local recent = lv and time.to_s(now - lv.last) < GROUP_SEC
        local join = d < Screen:scaleBySize(160) or (recent and d < Screen:scaleBySize(480))
        if not join or g.status or g.note or not self:screenOf(g) then g = nil end
    end
    -- only this group changes: a cheap undo step (copying all the page's ink
    -- at every pen lift made the next stroke lag)
    self:edit(function()
        if not g then
            g = { id = newId(), created = os.time() }
            self.fresh = g
            lv = { screen = {} }
            self.fresh_live[g] = lv
            table.insert(self.data.groups, g)
        end
        table.insert(lv.screen, pts)
        lv.last = now
        lv.box = Book.bboxOf(lv.screen)
        if not self.book:anchor(g, lv.screen) then
            logger.warn("Glossator: could not anchor ink")
        end
    end, g and { g } or {})
    -- the chip, once you've paused: not while the pen still hovers over the
    -- page (you're about to write more), and not where you'd write next
    if self.chip and self.chip.group ~= g then
        self:settleLater(grow(self.chip.rect, 2))
        self:hideChip(false)
    end
    self.fresh_lift = time.now()
    self.show_chip_cb = self.show_chip_cb or guarded(function() self:maybeShowChip() end)
    UIManager:unschedule(self.show_chip_cb)
    UIManager:scheduleIn(G_reader_settings:readSetting("glossator_chip_delay") or CHIP_DELAY, self.show_chip_cb)
end

function Ink:maybeShowChip()
    local g = self.fresh
    if not g or g.note or g.status == "asking" then return end
    if self.settle_rect and not self.stroke then self:settle() end
    local now = time.now()
    local waited = self.fresh_lift and time.to_s(now - self.fresh_lift) or CHIP_MAX_WAIT
    local hovering = self.pen_near and time.to_s(now - self.pen_near) < CHIP_HOVER
    if (self.stroke or hovering) and waited < CHIP_MAX_WAIT then
        UIManager:scheduleIn(0.6, self.show_chip_cb)
        return
    end
    self:showChip(g)
end

-- The eraser: whole strokes it touches go, or (precise) just where it passed.
function Ink:eraseAlong(path)
    local reach = Screen:scaleBySize(G_reader_settings:readSetting("inkai_eraser") == "precise" and 10 or 14)
    local precise = self:eraserMode() == "precise"
    path = Edit.densify(path, reach / 2)
    local pbox = Book.bboxOf({ path })
    local changed = false
    local token = self.history:begin(self:groupsOnScreen())
    for gi = #self.data.groups, 1, -1 do
        local g = self.data.groups[gi]
        local sc = self:screenOf(g)
        if sc and #sc.strokes > 0 and rectGap(grow(sc.box, reach), pbox) == 0 then
            local keep_screen = {}
            local touched = false
            for _i, st in ipairs(sc.strokes) do
                if precise then
                    local runs, cut = Edit.cut(st, path, reach)
                    if cut then touched = true end
                    for _i, r in ipairs(runs) do keep_screen[#keep_screen + 1] = r end
                elseif Edit.touches(st, path, reach) then
                    touched = true
                else
                    keep_screen[#keep_screen + 1] = st
                end
            end
            if touched then
                changed = true
                if #keep_screen == 0 and not g.note then
                    table.remove(self.data.groups, gi)
                    if self.fresh == g then self.fresh = nil end
                elseif #keep_screen == 0 then
                    g.strokes = {}
                else
                    self.book:anchor(g, keep_screen)
                    if self.fresh_live[g] then self.fresh_live[g].screen = keep_screen end
                end
            end
        end
    end
    if changed then
        self.history:commit(token, self:groupsAfter(token))
        self:hideChip(false)
        self:save()
    end
    -- clear the eraser's trail either way
    self:repaint(grow(pbox, reach + 4))
end

-- The groups an edit begun with `token` leaves: those it started with that
-- still exist, and any on the screen now.
function Ink:groupsAfter(token)
    local before = {}
    for _i, g in ipairs(token.before) do before[g.id] = true end
    local out = {}
    for _i, g in ipairs(self.data.groups) do
        if before[g.id] or self:screenOf(g) then out[#out + 1] = g end
    end
    return out
end

------------------------------------------------------------------------------
-- The marker
------------------------------------------------------------------------------

-- A marker stroke becomes KOReader's own highlight of the text under it (it is
-- then listed with the book's highlights and exported with them). Where there
-- is no text (a scan, a figure) it stays as a marker stroke.
function Ink:markerDone(pts)
    local box = Book.bboxOf({ pts })
    local sel = self:textUnder(pts, box)
    local hl = self.ui.highlight
    if sel and hl then
        hl.selected_text = sel
        local ok, idx = pcall(hl.saveHighlight, hl)
        hl.selected_text = nil
        if self.ui.rolling then pcall(self.ui.document.clearSelection, self.ui.document) end
        if ok and idx then
            self:repaint(grow(box, Paint.markerRadius() + 4))
            -- offer Ask AI about the highlighted text
            local g = { id = newId(), created = os.time(), transient = true, selected_text = sel.text }
            if self.book:anchorSelection(g, sel) then
                self:showChip(g)
            end
            return
        end
        if not ok then logger.warn("Glossator: highlight:", idx) end
    end
    self:addStroke(pts)
    self:repaint(grow(box, Paint.markerRadius() + 4))
end

-- The text a marker stroke runs over, as ReaderHighlight's selected_text, or nil.
function Ink:textUnder(pts, box)
    local doc = self.ui.document
    local line_h = Screen:scaleBySize(36)
    local x0, y0, x1, y1
    if box.h < line_h then
        -- along one line: from its left end to its right end, at its middle
        local my = box.y + box.h / 2
        x0, y0, x1, y1 = box.x + 2, my, box.x + box.w - 2, my
    else
        x0, y0, x1, y1 = pts[1], pts[2], pts[#pts - 1], pts[#pts]
        if y1 < y0 then x0, y0, x1, y1 = x1, y1, x0, y0 end
    end
    local ok, sel
    if self.ui.paging then
        local view = self.ui.view
        local p0 = view:screenToPageTransform({ x = x0, y = y0 })
        local p1 = view:screenToPageTransform({ x = x1, y = y1 })
        if not (p0 and p1 and p0.page and p0.page == p1.page) then return nil end
        ok, sel = pcall(doc.getTextFromPositions, doc, p0, p1)
    else
        ok, sel = pcall(doc.getTextFromPositions, doc, { x = x0, y = y0 }, { x = x1, y = y1 })
    end
    if ok and sel and sel.pos0 and sel.pos1 and type(sel.text) == "string" and sel.text:match("%S") then
        return sel
    end
    return nil
end

------------------------------------------------------------------------------
-- The lasso
------------------------------------------------------------------------------

function Ink:lassoDone(poly)
    local box = Book.bboxOf({ poly })
    self:repaint(grow(box, 6)) -- the dotted loop goes
    local items = {}
    local sbox
    for _i, g in ipairs(self.data.groups) do
        local sc = self:screenOf(g)
        if sc then
            for i, st in ipairs(sc.strokes) do
                if Edit.lassoTakes(poly, st) then
                    items[#items + 1] = { g = g, i = i }
                    sbox = union(sbox, Book.bboxOf({ st }))
                end
            end
        end
    end
    if #items == 0 then return end
    self.sel = { items = items, box = grow(sbox, Screen:scaleBySize(10)) }
    self:showSelectionChip()
    self:repaint(self.sel.box)
end

function Ink:clearSelection()
    local s = self.sel
    self.sel = nil
    if self.chip and self.chip.selection then self:hideChip(false) end
    if s then self:repaint(grow(s.box, 4)) end
end

-- The selected strokes, as screen strokes, and taken out of their groups
-- (`take`), which are re-anchored or removed when left empty.
function Ink:selectedStrokes(take)
    local out = {}
    local by = {}
    for _i, it in ipairs(self.sel.items) do
        local sc = self:screenOf(it.g)
        if sc and sc.strokes[it.i] then
            out[#out + 1] = sc.strokes[it.i]
            by[it.g] = by[it.g] or {}
            by[it.g][it.i] = true
        end
    end
    if take then
        for g, idx in pairs(by) do
            local sc = self:screenOf(g)
            local keep = {}
            for i, st in ipairs(sc.strokes) do
                if not idx[i] then keep[#keep + 1] = st end
            end
            if #keep == 0 and not g.note then
                for k, o in ipairs(self.data.groups) do
                    if o == g then table.remove(self.data.groups, k) break end
                end
            elseif #keep == 0 then
                g.strokes = {}
            else
                self.book:anchor(g, keep)
            end
            self.rev = self.rev + 1 -- screens of the groups changed
        end
    end
    return out
end

function Ink:showSelectionChip()
    local s = self.sel
    if not s then return end
    local g = { id = "selection", box = s.box }
    self:showChip(g, false, {
        { label = _("Ask AI"), action = function() self:askSelectedInk() end },
        { label = _("Delete"), action = function() self:deleteSelection() end },
    })
    if self.chip then self.chip.selection = true end
end

function Ink:deleteSelection()
    self:edit(function() self:selectedStrokes(true) end)
    self:notesChanged()
    self.sel = nil
    self:hideChip(false)
    self:repaint()
end

function Ink:askSelectedInk()
    local g
    self:edit(function()
        local strokes = self:selectedStrokes(true)
        g = { id = newId(), created = os.time() }
        self.book:anchor(g, strokes)
        table.insert(self.data.groups, g)
    end)
    self.sel = nil
    self:hideChip(false)
    self:repaint()
    self:ask(g)
end

-- While dragging the selection: its dashed box follows the pen.
function Ink:liveMoveBox()
    local s = self.stroke
    local b = self.sel.box
    local dx, dy = s[3] - s[1], s[4] - s[2]
    local nb = { x = floor(b.x + dx), y = floor(b.y + dy), w = b.w, h = b.h }
    local old = self.move_box or b
    Paint.dashedRect(Screen.bb, nb.x, nb.y, nb.w, nb.h, Blitbuffer.COLOR_GRAY_4)
    self.move_box = nb
    self:liveDirty(union(grow(old, 2), grow(nb, 2)))
end

function Ink:finishMove(s)
    local dx, dy = (s[3] or s[1]) - s[1], (s[4] or s[2]) - s[2]
    self.move_box = nil
    if abs(dx) + abs(dy) < 4 then return end
    self:edit(function()
        local by = {}
        for _i, it in ipairs(self.sel.items) do
            by[it.g] = by[it.g] or {}
            by[it.g][it.i] = true
        end
        for g, idx in pairs(by) do
            local sc = self:screenOf(g)
            local moved = {}
            for i, st in ipairs(sc.strokes) do
                if idx[i] then
                    local t = Book.withAttrs({}, st)
                    for k = 1, #st, 2 do t[k], t[k + 1] = st[k] + dx, st[k + 1] + dy end
                    moved[#moved + 1] = t
                else
                    moved[#moved + 1] = st
                end
            end
            self.book:anchor(g, moved)
        end
    end)
    self:notesChanged()
    local b = self.sel.box
    self.sel.box = { x = b.x + dx, y = b.y + dy, w = b.w, h = b.h }
    self:hideChip(false)
    self:repaint()
    self:showSelectionChip()
end

------------------------------------------------------------------------------
-- Taps (finger, or the pen on the toolbar, the chip or a note)
------------------------------------------------------------------------------

function Ink:onTap(ges)
    return self:tapAt(ges.pos.x, ges.pos.y, true)
end

function Ink:tapAt(x, y, finger)
    -- the toolbar works even when ink is hidden
    if self.toolbar.rect then
        local it, inside = self.toolbar:hit(x, y)
        if it then
            self:toolbarAction(it)
            return true
        end
        if inside then return true end
        if self.toolbar.options then
            self.toolbar.options = nil
            self:repaint()
            return true
        end
    end
    if not self:shown() then return false end
    local chip = self.chip
    if chip and contains(chip.rect, x, y) then
        if chip.group.status == "asking" then return true end
        for _i, seg in ipairs(chip.segments) do
            if contains(seg.rect, x, y) then
                seg.action()
                return true
            end
        end
        return true
    end
    local g = self:answerAt(x, y)
    if g then
        self:openAnswer(g)
        return true
    end
    if self.sel then
        self:clearSelection()
        return true
    end
    g = self:inkAt(x, y)
    if g then
        self.fresh = nil
        self:showChip(g, true)
        return true
    end
    if chip and finger then
        -- tapping elsewhere leaves the ink as a plain annotation (and only
        -- puts the chip away: the page doesn't turn under you); it also ends a
        -- written follow-up that was waiting for ink
        self:hideChip(true)
        return true
    end
    return false
end

function Ink:answerAt(x, y)
    for _i, h in ipairs(self.cache.hits or {}) do
        if contains(h.rect, x, y) then return h.group end
    end
end

-- Ink under (x, y): close to one of its strokes, not just in its box.
function Ink:inkAt(x, y)
    local reach = Screen:scaleBySize(14)
    for _i, g in ipairs(self.data.groups) do
        local sc = self:screenOf(g)
        if sc and sc.box and #sc.strokes > 0 and contains(grow(sc.box, reach), x, y) then
            for _i, st in ipairs(sc.strokes) do
                for i = 1, #st, 2 do
                    if abs(st[i] - x) < reach and abs(st[i + 1] - y) < reach then return g end
                end
            end
        end
    end
end

------------------------------------------------------------------------------
-- The toolbar
------------------------------------------------------------------------------

function Ink:toolbarAction(it)
    local tb = self.toolbar
    local old = union(tb.rect, tb.opt_rect)
    if it.opt then
        if it.opt == "pen" then G_reader_settings:saveSetting("inkai_pen_width", it.arg)
        elseif it.opt == "eraser" then G_reader_settings:saveSetting("inkai_eraser", it.arg) end
        tb.options = nil
    elseif it.id == "openbar" then
        tb:setState("open")
    elseif it.id == "close" then
        tb:setState("tab")
    elseif it.tool then
        if self:tool() == it.id and (it.id == "pen" or it.id == "eraser") then
            tb.options = tb.options ~= it.id and it.id or nil
        else
            G_reader_settings:saveSetting("inkai_tool", it.id)
            tb.options = nil
        end
        if it.id ~= "lasso" and self.sel then self:clearSelection() end
    elseif it.id == "undo" then
        tb.options = nil
        self:undo()
    elseif it.id == "redo" then
        tb.options = nil
        self:redo()
    elseif it.id == "ink" then
        self:onGlossatorToggleShow()
        return
    elseif it.id == "ai" then
        if self.fresh and self:screenOf(self.fresh) then
            self:ask(self.fresh)
        else
            self:explainPage()
        end
    end
    tb:layout()
    self.place_cache = {} -- notes keep clear of the bar
    self:repaint(union(old, union(tb.rect, tb.opt_rect)))
    if it.id == "openbar" or it.id == "close" then self:repaint() end
end

function Ink:onGlossatorToolbar()
    local tb = self.toolbar
    tb:setState(tb:state() == "open" and "tab" or "open")
    self.place_cache = {}
    self:repaint()
    return true
end

------------------------------------------------------------------------------
-- The Ask AI chip
------------------------------------------------------------------------------

function Ink:chipFace()
    return Font:getFace("cfont", 17)
end

--[[--
Show the chip by group `g`'s ink (or `g.box`, for the lasso's selection).
`segments` replaces the default ones: { { label, action } }.
]]
function Ink:showChip(g, with_erase, segments)
    if not g or not self:shown() then return end
    local sc = g.box and g.id == "selection" and { box = g.box, strokes = {} } or self:screenOf(g)
    if not sc then return end
    local old = self.chip and self.chip.rect
    if not segments then
        local label = g.status == "asking" and _("Thinking\u{2026}")
            or g.status == "error" and _("Try again")
            or g.thread and _("Ask follow-up")
            or _("Ask AI")
        segments = { { label = label, action = function() self:ask(g) end, icon = true } }
        if with_erase and g.status ~= "asking" then
            segments[2] = { label = _("Erase"), action = function() self:deleteGroup(g, true) end }
        end
    end
    segments[1].icon = true
    local face = self:chipFace()
    local h = Screen:scaleBySize(44)
    local icon = floor(h * 0.42)
    local pad = floor(h * 0.42)
    local tw_all = 0
    for i, seg in ipairs(segments) do
        local tw = RenderText:sizeUtf8Text(0, nil, face, seg.label, true).x
        seg.w = (i == 1 and (pad + icon + floor(pad * 0.6)) or pad) + tw + pad
        tw_all = tw_all + seg.w
    end
    local W, H = Screen:getWidth(), Screen:getHeight()
    local m = Screen:scaleBySize(10)
    local b = sc.box
    -- somewhere blank by the ink, but not where you'd write next (to its
    -- right, or just below): above it first, then to its left
    local cands = {
        { b.x + b.w - tw_all, b.y - h - m },
        { b.x, b.y - h - m },
        { b.x + b.w + m, b.y - h - m },
        { b.x - tw_all - m, b.y + max(0, (b.h - h) / 2) },
        { b.x - tw_all - m, b.y - h - m },
        { b.x + b.w - tw_all, b.y + b.h + 2 * h },
        { b.x + b.w + m, b.y + max(0, (b.h - h) / 2) },
    }
    local x, y
    local space = g.a and self:freeSpace(g)
    local function free(cx, cy)
        if cx < m or cy < m or cx + tw_all > W - m or cy + h > H - m then return false end
        for _i, r in ipairs(self.toolbar:covers()) do
            if rectGap(r, { x = cx, y = cy, w = tw_all, h = h }) == 0 then return false end
        end
        if not space then return true end
        local o = space.origin_now
        return Place.isFree(space.grid, { x = cx - o.x, y = cy - o.y, w = tw_all, h = h })
    end
    for _i, c in ipairs(cands) do
        if free(c[1], c[2]) then x, y = c[1], c[2] break end
    end
    if not x and space then
        local o = space.origin_now
        local best = Place.find(space.grid, { x = b.x - o.x, y = b.y - o.y, w = b.w, h = b.h },
            { { w = tw_all, h = h } }, m)
        if best and best.dist < Screen:scaleBySize(260) then x, y = best.x + o.x, best.y + o.y end
    end
    if not x then
        x, y = b.x + b.w + m, b.y + max(0, (b.h - h) / 2)
        if x + tw_all > W - m then x = b.x - tw_all - m end
        if x < m then
            x = min(max(m, b.x + b.w - tw_all), W - tw_all - m)
            y = b.y + b.h + m
            if y + h > H - m then y = b.y - h - m end
        end
    end
    x = floor(min(max(m, x), W - tw_all - m))
    y = floor(min(max(m, y), H - h - m))
    local sx = x
    for _i, seg in ipairs(segments) do
        seg.rect = { x = sx, y = y, w = seg.w, h = h }
        sx = sx + seg.w
    end
    self.chip = { group = g, rect = { x = x, y = y, w = tw_all, h = h }, segments = segments, icon = icon, pad = pad }
    self:repaint(union(old, self.chip.rect))
    self.hide_chip_cb = self.hide_chip_cb or guarded(function()
        if self.chip and self.chip.group.status ~= "asking" and not self.chip.selection then
            self:hideChip(true)
        end
    end)
    UIManager:unschedule(self.hide_chip_cb)
    if g.status ~= "asking" then UIManager:scheduleIn(CHIP_LINGER, self.hide_chip_cb) end
end

function Ink:hideChip(repaint)
    if self.show_chip_cb then UIManager:unschedule(self.show_chip_cb) end
    if self.hide_chip_cb then UIManager:unschedule(self.hide_chip_cb) end
    local c = self.chip
    if not c then return end
    self.chip = nil
    if repaint then self:repaint(grow(c.rect, 2)) end
end

-- A small four-pointed sparkle, drawn (no font needed).
local function sparkle(bb, cx, cy, r, color)
    local t = max(1, floor(r / 5))
    Math.line(bb, cx, cy - r, cx, cy + r, t, color)
    Math.line(bb, cx - r, cy, cx + r, cy, t, color)
    local q = r * 0.45
    Math.line(bb, cx - q, cy - q, cx + q, cy + q, max(1, t - 1), color)
    Math.line(bb, cx - q, cy + q, cx + q, cy - q, max(1, t - 1), color)
    bb:paintRect(floor(cx - t), floor(cy - t), 2 * t + 1, 2 * t + 1, color)
end

function Ink:paintChip(bb, ox, oy)
    local c = self.chip
    if not c or self.shooting then return end
    local r = c.rect
    local x, y = ox + r.x, oy + r.y
    local rad = floor(r.h / 2)
    bb:paintRoundedRect(x, y, r.w, r.h, Blitbuffer.COLOR_WHITE, rad)
    bb:paintBorder(x, y, r.w, r.h, Screen:scaleBySize(1.5), Blitbuffer.COLOR_BLACK, rad)
    local face = self:chipFace()
    local asc = RenderText:sizeUtf8Text(0, nil, face, "Ag", true)
    local base = y + floor((r.h + asc.y_top - asc.y_bottom) / 2)
    for i, seg in ipairs(c.segments) do
        local sx = ox + seg.rect.x
        local tx = sx + c.pad
        if i == 1 then
            sparkle(bb, sx + c.pad + c.icon / 2, y + r.h / 2, c.icon / 2, Blitbuffer.COLOR_BLACK)
            tx = sx + c.pad + c.icon + floor(c.pad * 0.6)
        else
            bb:paintRect(sx, y + floor(r.h * 0.22), max(1, Screen:scaleBySize(1)), floor(r.h * 0.56), Blitbuffer.COLOR_DARK_GRAY)
        end
        RenderText:renderUtf8Text(bb, tx, base, face, seg.label, true, false,
            i == 1 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_4)
    end
end

------------------------------------------------------------------------------
-- Painting ink and notes over the page
------------------------------------------------------------------------------

function Ink:screenOf(g)
    local key = self.book:layoutKey() .. "#" .. self.rev
    if self.cache.key ~= key then
        self.cache = { key = key, screens = {}, hits = {} }
    end
    local s = self.cache.screens[g]
    if s == nil then
        s = self.book:screenOf(g) or false
        self.cache.screens[g] = s
    end
    return s or nil
end

-- Glossator paints over the page on every repaint: a mistake here must never
-- stop the reader from drawing its pages.
function Ink:paint(bb, x, y)
    local ok, err = pcall(self.paintUnsafe, self, bb, x, y)
    if not ok then
        logger.err("Glossator: painting failed:", err)
        self.cache = {}
        self.place_cache = {}
    end
end

function Ink:paintUnsafe(bb, x, y)
    self.toolbar:layout()
    if not self:shown() then
        self.cache.hits = {}
        self.toolbar:paint(bb, x, y)
        return
    end
    -- the reflowing page as it is, before anything is painted over it
    local key = self.book:layoutKey() .. "#" .. self.rev
    if self.cache.key ~= key then
        self.cache = { key = key, screens = {}, hits = {} }
    end
    if not self.book:paging() and self.cache.sampled ~= key and #self.data.groups > 0 then
        local ok, err = pcall(self.book.sampleScreen, self.book, bb)
        if not ok then logger.warn("Glossator: sample:", err) end
        self.cache.sampled = key
    end
    local smooth = G_reader_settings:readSetting("inkai_smooth") ~= false
    local on = {}
    for _i, g in ipairs(self.data.groups) do
        local sc = self:screenOf(g)
        if sc then
            on[#on + 1] = g
            for _i, st in ipairs(sc.strokes) do
                Paint.stroke(bb, x, y, st, smooth)
            end
            -- a note asked about selected text: a light pencil underline
            if #sc.strokes == 0 and g.selected_text and sc.box then
                local b = sc.box
                bb:paintRect(x + floor(b.x), y + floor(b.y + b.h + 2), floor(b.w), max(1, Screen:scaleBySize(1)), Blitbuffer.COLOR_GRAY_7)
            end
        end
    end
    -- the stroke being written (if anything repaints mid-stroke)
    local s = self.stroke
    if s and s.tool == "pen" and #s >= 2 then Paint.stroke(bb, x, y, s, false) end
    self.cache.hits = {}
    for _i, g in ipairs(on) do
        if g.note then
            local p = self:placeOf(g)
            if p then
                local ok, err = pcall(self.paintNote, self, bb, x, y, g, p)
                if not ok then logger.warn("Glossator: note:", err) end
            end
        end
    end
    -- the lasso's selection
    if self.sel and not self.shooting then
        local b = self.sel.box
        Paint.dashedRect(bb, x + floor(b.x), y + floor(b.y), floor(b.w), floor(b.h), Blitbuffer.COLOR_GRAY_4)
    end
    self:paintChip(bb, x, y)
    if not self.shooting then self.toolbar:paint(bb, x, y) end
end

-- Variants of a note to try: full text at a few widths, a smaller hand where
-- room is tight, then cut to three lines (tap to read the rest).
function Ink:variants(g)
    local px = self:notePx()
    local W = Screen:getWidth()
    local pad = floor(px * 0.2)
    local out = {}
    local widths = { floor(W * 0.4), floor(W * 0.32), floor(W * 0.25), floor(W * 0.19), floor(W * 0.14), floor(W * 0.1) }
    for _i, cut in ipairs({ false, true }) do
        for _i, scale in ipairs({ 1, 0.84 }) do
            for i, w in ipairs(widths) do
                local L = Rich.layout(g.note, { width = w - 2 * pad, px = px * scale, hand = self:hand(),
                    max_lines = cut and 3 or nil })
                if not cut or L.truncated then
                    local hint = (cut or g.more or (g.replies and #g.replies > 0)) and floor(px * 0.7) or 0
                    out[#out + 1] = {
                        w = L.w + 2 * pad, h = L.h + 2 * pad + hint, L = L, pad = pad, hint = hint,
                        penalty = (i - 1) * 25 + (cut and 260 or 0) + (scale < 1 and 90 or 0),
                        cut = cut,
                    }
                end
            end
        end
    end
    return out
end

--[[--
The blank space around group `g`, with every other bit of ink on its page (or
screen) and the toolbar marked: { grid, toScreen, origin_now, key, space }.
For a fixed page the grid is the page's (see Book:pageSpace), the same however
it is scrolled, so notes keep their places while you scroll.
]]
function Ink:freeSpace(g)
    local space = self.book:spaceFor(g, self:screenOf(g))
    if not space then return nil end
    local grid = Place.dilate(Place.copy(space.grid), 1)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local origin = space.toScreen({ x = 0, y = 0, w = 0, h = 0 })
    local mates = {}
    if space.page then
        for _i, o in ipairs(self.data.groups) do
            if o.a and o.a.page == space.page then
                local b = self.book:layoutBox(o, space)
                if b then Place.mark(grid, b, Screen:scaleBySize(8)) end
                mates[#mates + 1] = o
            end
        end
    else
        for _i, o in ipairs(self.data.groups) do
            local osc = self:screenOf(o)
            if osc and osc.box then
                Place.mark(grid, osc.box, Screen:scaleBySize(8))
                mates[#mates + 1] = o
            end
        end
    end
    local big = 100000
    local ox = origin.x
    -- left and right of the screen (a zoomed page's cropped margins)
    Place.mark(grid, { x = -big, y = -big, w = big - ox, h = 3 * big })
    Place.mark(grid, { x = W - ox, y = -big, w = big, h = 3 * big })
    -- the open toolbar's columns, the whole height (stable while scrolling);
    -- the folded tab sits in the bottom band, which is kept clear anyway
    for _i, r in ipairs(self.toolbar:columns()) do
        Place.mark(grid, { x = r.x - ox, y = -big, w = r.w, h = 3 * big }, Screen:scaleBySize(6))
    end
    if not self.ui.view.page_scroll then
        -- the screen's top and bottom bands (status bar, Kindle bars)
        local oy = origin.y
        Place.mark(grid, { x = -big, y = -big, w = 3 * big, h = big - oy + floor(H * 0.03) })
        Place.mark(grid, { x = -big, y = H - floor(H * 0.045) - oy, w = 3 * big, h = big })
    end
    local key = space.key
    if not self.ui.view.page_scroll then key = key .. "|" .. floor(origin.y) end
    return { grid = grid, toScreen = space.toScreen, origin_now = origin, key = key, space = space, mates = mates }
end

-- Where group `g`'s note goes: { rect (screen), v, target, dist, overlay, hit }.
-- Places are found for all the notes of a page (or screen) at once, in the order
-- they were written, and kept until the page's layout or the ink changes.
function Ink:placeOf(g)
    local sc = self:screenOf(g)
    if not sc then return nil end
    local ckey = table.concat({ self:spaceKey(g), self.note_rev, self:hand(), self:noteSize(), self.toolbar:state() }, "#")
    local entry = self.place_cache[ckey]
    if not entry then
        entry = self:placeNotes(g)
        if not entry then return nil end
        -- a few pages' worth, no more
        local n = 0
        for _ in pairs(self.place_cache) do n = n + 1 end
        if n > 24 then self.place_cache = {} end
        self.place_cache[ckey] = entry
    end
    local p = entry.places[g.id]
    if not p then return nil end
    local o = entry.toScreen({ x = 0, y = 0, w = 0, h = 0 })
    local rect = { x = o.x + p.rel.x, y = o.y + p.rel.y, w = p.rel.w, h = p.rel.h }
    local out = { rect = rect, v = p.v, target = sc.box, dist = p.dist, overlay = p.overlay,
        hit = grow(rect, Screen:scaleBySize(6)), grid = entry.grid, origin = o }
    self.cache.hits[#self.cache.hits + 1] = { rect = out.hit, group = g }
    return out
end

function Ink:spaceKey(g)
    local a = g.a or {}
    if a.page then
        local sx, sy, zoom = self.book:toScreen(a.page, 0, 0)
        if not sx then return "none" end
        local k = table.concat({ "p", a.page, zoom, floor(sx), Screen:getWidth(), Screen:getHeight() }, "|")
        if not self.ui.view.page_scroll then k = k .. "|" .. floor(sy) end
        return k
    end
    return self.book:layoutKey()
end

function Ink:placeNotes(g)
    local fs = self:freeSpace(g)
    if not fs then return nil end
    local W, H = Screen:getWidth(), Screen:getHeight()
    local grid = fs.grid
    local places = {}
    local list = {}
    for _i, o in ipairs(fs.mates) do
        if o.note then list[#list + 1] = o end
    end
    table.sort(list, function(a, b) return (a.created or 0) < (b.created or 0) end)
    for _i, o in ipairs(list) do
        local target
        if fs.space.page then
            target = self.book:layoutBox(o, fs.space)
        else
            local osc = self:screenOf(o)
            target = osc and osc.box
        end
        if target then
            local vars = self:variants(o)
            local best = Place.find(grid, target, vars, Screen:scaleBySize(6))
            if best and best.dist < H * 0.3 then
                places[o.id] = { rel = { x = best.x, y = best.y, w = best.w, h = best.h }, v = best.variant, dist = best.dist }
                Place.mark(grid, best, Screen:scaleBySize(6))
            else
                -- nowhere blank near it: a paper slip just under (or over) the ink
                local v
                for _i, cand in ipairs(vars) do
                    if cand.cut or not v then v = cand end
                    if cand.cut then break end
                end
                local m = Screen:scaleBySize(8)
                local o0 = fs.origin_now
                local x = min(max(m - o0.x, target.x), W - o0.x - v.w - m)
                local y = target.y + target.h + m
                if o0.y + y + v.h > H * 0.95 then y = max(m - o0.y, target.y - v.h - m) end
                places[o.id] = { rel = { x = x, y = y, w = v.w, h = v.h }, v = v, dist = 0, overlay = true }
            end
        end
    end
    return { places = places, grid = grid, toScreen = fs.toScreen }
end

function Ink:paintNote(bb, ox, oy, g, p)
    local r = p.rect
    local x, y = ox + floor(r.x), oy + floor(r.y)
    if p.overlay then
        bb:paintRoundedRect(x, y, r.w, r.h, Blitbuffer.COLOR_WHITE, Screen:scaleBySize(6))
        bb:paintBorder(x, y, r.w, r.h, Screen:scaleBySize(1), Blitbuffer.COLOR_GRAY_9, Screen:scaleBySize(6))
    end
    Rich.paint(p.v.L, bb, x + p.v.pad, y + p.v.pad, NOTE_INK)
    -- a pencil line from the note to the ink, when they are apart
    local t = p.target
    if not p.overlay and p.dist > Screen:scaleBySize(18) then
        local ax = (r.x > t.x + t.w) and r.x or (r.x + r.w < t.x) and (r.x + r.w) or (r.x + r.w / 2)
        local ay = (r.y > t.y + t.h) and r.y or (r.y + r.h < t.y) and (r.y + r.h) or (r.y + min(r.h / 2, Screen:scaleBySize(20)))
        local bx = min(max(ax, t.x), t.x + t.w)
        local by = min(max(ay, t.y), t.y + t.h)
        local dx, dy = bx - ax, by - ay
        local len = sqrt(dx * dx + dy * dy)
        -- the curve it would draw, and only where all of it is blank (never a
        -- line across the text)
        local cx, cy = ax + dx * 0.5 - dy * 0.12, ay + dy * 0.5 + dx * 0.12
        local function bez(tt)
            local u = 1 - tt
            return u * u * ax + 2 * u * tt * cx + tt * tt * bx, u * u * ay + 2 * u * tt * cy + tt * tt * by
        end
        local clear = len > 1
        if clear and p.grid then
            local n = max(8, floor(len / 6))
            for i = 1, n - 1 do
                local qx, qy = bez(i / n)
                -- the ends touch the note and the ink themselves
                local near_end = rectGap({ x = qx, y = qy, w = 0, h = 0 }, r) < Screen:scaleBySize(10) or rectGap({ x = qx, y = qy, w = 0, h = 0 }, t) < Screen:scaleBySize(16)
                if not near_end and not Place.isFree(p.grid, { x = qx - p.origin.x - 1, y = qy - p.origin.y - 1, w = 2, h = 2 }) then
                    clear = false
                    break
                end
            end
        end
        if clear then
            local s0, s1 = Screen:scaleBySize(4) / len, 1 - Screen:scaleBySize(6) / len
            local px0, py0 = ax + dx * s0, ay + dy * s0
            local n = 12
            for i = 1, n do
                local tt = s0 + (s1 - s0) * i / n
                local u = 1 - tt
                local qx = u * u * ax + 2 * u * tt * cx + tt * tt * bx
                local qy = u * u * ay + 2 * u * tt * cy + tt * tt * by
                Paint.segment(bb, ox + px0, oy + py0, ox + qx, oy + qy, max(0.7, Screen:scaleBySize(70) / 100), Blitbuffer.COLOR_GRAY_6)
                px0, py0 = qx, qy
            end
        end
    end
    -- a note cut short, or with more to read, says so
    local nrep = g.replies and #g.replies or 0
    if p.v.cut or g.more or nrep > 0 then
        local face = Fonts.hand(self:hand(), self:notePx() * 0.62)
        local more = p.v.cut and _("tap to read on") or _("tap for more")
        if nrep > 0 then
            more = nrep == 1 and _("1 follow-up") or T(_("%1 follow-ups"), nrep)
        end
        local tw = RenderText:sizeUtf8Text(0, nil, face, more, true).x
        local bx = x + r.w - tw - p.v.pad
        local by = y + r.h - p.v.pad
        if bx < x then bx = x end
        RenderText:renderUtf8Text(bb, bx, by, face, more, true, false, Blitbuffer.COLOR_GRAY_7)
    end
end

------------------------------------------------------------------------------
-- Asking
------------------------------------------------------------------------------

function Ink:pageText()
    local ui = self.ui
    local page = self.book:currentPage()
    local ok, text = pcall(function()
        if ui.rolling then
            local res = ui.document:getTextFromPositions({ x = 0, y = 0 },
                { x = Screen:getWidth(), y = Screen:getHeight() }, true)
            return res and res.text
        end
        local words = {}
        for _i, line in ipairs(ui.document:getPageText(page) or {}) do
            local w = {}
            for _i, word in ipairs(line) do
                if word.word then table.insert(w, word.word) end
            end
            table.insert(words, table.concat(w, " "))
        end
        return table.concat(words, "\n")
    end)
    return ok and text or nil
end

function Ink:pageContext(g, sc)
    local ui = self.ui
    local lines = {}
    local props = ui.doc_props or {}
    if props.display_title then
        table.insert(lines, "Book: " .. props.display_title .. (props.authors and (" by " .. props.authors) or ""))
    end
    local page = self.book:currentPage()
    if page then
        table.insert(lines, T("Location: page %1 of %2", page, ui.document:getPageCount()))
    end
    if g and g.typed then
        table.insert(lines, "There is no new handwriting: the user typed this follow-up question:\n\"\"\"\n"
            .. g.typed .. "\n\"\"\"\nAnswer it; in <transcription> put the question.")
    elseif g and g.selected_text then
        table.insert(lines, "There is no handwriting: the user selected this text on the page and asked you about it:\n\"\"\"\n"
            .. g.selected_text .. "\n\"\"\"\nExplain it in the context of the page; in <transcription> put \"selected: \" and its first few words.")
    elseif sc and sc.box then
        local b = sc.box
        local s = self.image_scale or 1
        table.insert(lines, T("The ink is at x=%1..%2, y=%3..%4 on the page image.",
            floor(b.x * s), floor((b.x + b.w) * s), floor(b.y * s), floor((b.y + b.h) * s)))
    end
    local text = self:pageText()
    if text and text ~= "" then
        table.insert(lines, "Text on this page (extracted, math may be garbled):\n\"\"\"\n" .. text .. "\n\"\"\"")
    end
    return table.concat(lines, "\n\n")
end

-- The earlier questions and answers this one follows up, oldest first.
function Ink:threadOf(g)
    local byid = {}
    for _i, o in ipairs(self.data.groups) do byid[o.id] = o end
    local out = {}
    local cur = g.thread and byid[g.thread]
    while cur and #out < THREAD_MAX do
        if cur.note then
            table.insert(out, 1, { question = cur.question, answer = cur.note .. (cur.more and ("\n\n" .. cur.more) or "") })
        end
        cur = cur.thread and byid[cur.thread]
    end
    return out
end

-- The page as Claude sees it: the screen, at most IMAGE_MAX on its long side
-- (enough to read, and much cheaper than the Scribe's full 1860x2480), and a
-- close-up of the area around the ink at full resolution (Claude reads small
-- math better close up). KOReader's own screenshot does the capture.
function Ink:writeImages(sc)
    local ok = pcall(Screen.shot, Screen, self.page_path)
    if not ok then return false, false end
    self.image_scale = 1
    local RenderImage = require("ui/renderimage")
    local okr, full = pcall(RenderImage.renderImageFile, RenderImage, self.page_path, false)
    if not (okr and full) then return true, false end
    local W, H = full:getWidth(), full:getHeight()
    local closeup = false
    if sc and sc.box then
        local m = Screen:scaleBySize(120)
        local b = sc.box
        local x0, y0 = max(0, floor(b.x - m)), max(0, floor(b.y - m))
        local x1, y1 = min(W, floor(b.x + b.w + m)), min(H, floor(b.y + b.h + m))
        if x1 - x0 >= 8 and y1 - y0 >= 8 then
            closeup = pcall(function()
                local crop = Blitbuffer.new(x1 - x0, y1 - y0, full:getType())
                crop:blitFrom(full, 0, 0, x0, y0, x1 - x0, y1 - y0)
                crop:writePNG(self.crop_path)
                crop:free()
            end)
        end
    end
    local s = min(1, IMAGE_MAX / max(W, H))
    if s < 1 then
        local oks = pcall(function()
            local small = RenderImage:scaleBlitBuffer(full, floor(W * s), floor(H * s), false)
            small:writePNG(self.page_path)
            small:free()
        end)
        if oks then self.image_scale = s end
    end
    full:free()
    return true, closeup
end

-- Who to ask, and with which key: { provider, key, model }, and the test
-- answer (glossator_mock.txt) when there is one. Claude goes to Anthropic with
-- an Anthropic key, else through OpenRouter; every other model through
-- OpenRouter.
function Ink:credentials()
    local mock = self:readFile(self.mock_path) or self:readFile(self.old_mock_path)
    local keys = self:readKeys()
    local model = self:getModel()
    local or_id = model:match("^openrouter:(.+)$")
    local cred
    if or_id then
        if keys.openrouter then cred = { provider = "openrouter", key = keys.openrouter, model = or_id } end
    elseif keys.anthropic then
        cred = { provider = "anthropic", key = keys.anthropic, model = model }
    elseif keys.openrouter then
        cred = { provider = "openrouter", key = keys.openrouter, model = CLAUDE_ON_OPENROUTER[model] or ("anthropic/" .. model) }
    end
    if not cred and not mock then
        local text
        if or_id then
            text = T(_("%1 needs an OpenRouter key (it starts with sk-or-).\n\nPut it on a line of its own in\n%2"), self:modelLabel(model), self.key_path)
        else
            text = T(_("Put your API key in\n%1\n\nAn Anthropic key (sk-ant-…) or an OpenRouter key (sk-or-…), one per line."), self.key_path)
        end
        UIManager:show(InfoMessage:new{ text = text })
        return nil
    end
    return cred or { provider = "mock", model = model }, mock
end

function Ink:ask(g)
    if self.job then
        UIManager:show(Notification:new{ text = _("Still answering the last question.") })
        return
    end
    local key, mock = self:credentials()
    if not key and not mock then return end
    if mock then
        self:doAsk(g, key, mock)
    else
        NetworkMgr:runWhenOnline(function() self:doAsk(g, key) end)
    end
end

function Ink:doAsk(g, key, mock)
    local sc = self:screenOf(g)
    if not sc then return end
    if g.transient then
        -- a highlight's question becomes a note of the book now
        g.transient = nil
        table.insert(self.data.groups, g)
        self:save()
        sc = self:screenOf(g)
        if not sc then return end
    end
    g.status, g.err = "asking", nil
    self.fresh = nil
    -- the page with the ink, without the chip or the toolbar, for Claude
    self.shooting = true
    self:repaint()
    UIManager:forceRePaint()
    local shot_ok, closeup = self:writeImages(not (g.selected_text or g.typed) and sc or nil)
    local images = { self.page_path }
    if closeup then images[2] = self.crop_path end
    self.shooting = false
    self:showChip(g)
    self:repaint(self.toolbar.rect)
    if not shot_ok then
        self:failed(g, _("Could not capture the page."))
        return
    end
    self:runJob({
        cred = key,
        images = images,
        context = self:pageContext(g, sc),
        history = self:threadOf(g),
        mock = mock,
    }, function(res, err)
        if res then self:answered(g, res) else self:failed(g, err) end
    end)
end

-- Ask Claude in a background process, so the reader stays usable; `done(res, err)`.
function Ink:runJob(opts, done)
    if opts.cred then
        opts.provider, opts.api_key, opts.model = opts.cred.provider, opts.cred.key, opts.cred.model
        opts.cred = nil
    end
    local mock = opts.mock
    local pid, fd = ffiutil.runInSubProcess(function(_, wfd)
        if mock then ffiutil.sleep(1) end
        local ok, res, err = pcall(Claude.ask, opts)
        local out = json.encode({ res = ok and res or nil, err = ok and err or tostring(res) })
        ffiutil.writeToFD(wfd, out, true)
    end, true)
    if not pid then
        done(nil, tostring(fd))
        return
    end
    self.job = { pid = pid, fd = fd, done = done, started = time.now() }
    self.poll_cb = self.poll_cb or guarded(function() self:poll() end)
    UIManager:scheduleIn(0.5, self.poll_cb)
end

function Ink:poll()
    local job = self.job
    if not job then return end
    local done = ffiutil.isSubProcessDone(job.pid)
    local n = ffiutil.getNonBlockingReadSize(job.fd)
    if n and n > 0 or done then
        local data = ffiutil.readAllFromFD(job.fd)
        if not done then ffiutil.isSubProcessDone(job.pid, true) end
        self.job = nil
        os.remove(self.page_path)
        os.remove(self.crop_path)
        local ok, r = pcall(json.decode, data or "")
        -- a mistake in handling the answer must not take the reader down (this
        -- runs from a timer, where KOReader catches nothing)
        local okd, err
        if not ok or type(r) ~= "table" then
            okd, err = pcall(job.done, nil, _("No answer came back."))
        elseif not r.res then
            okd, err = pcall(job.done, nil, r.err or _("No answer came back."))
        else
            okd, err = pcall(job.done, r.res)
        end
        if not okd then logger.err("Glossator: handling the answer:", err) end
        return
    end
    if time.to_s(time.now() - job.started) > 200 then
        ffiutil.terminateSubProcess(job.pid)
        self.job = nil
        pcall(job.done, nil, _("The answer took too long."))
        return
    end
    UIManager:scheduleIn(0.5, self.poll_cb)
end

function Ink:failed(g, msg)
    logger.warn("Glossator:", msg)
    g.status, g.err = "error", msg
    self:showChip(g)
    UIManager:show(InfoMessage:new{ text = tostring(msg), timeout = 6 })
end

function Ink:answered(g, res)
    g.status, g.err = nil, nil
    g.note, g.more, g.question = res.note, res.more, res.transcription
    g.model = self:getModel()
    -- the page and chapter, kept for exporting while the book is closed
    g.pageno = tonumber(self:pageLabel(g))
    if g.pageno and self.ui.toc then
        local ok, title = pcall(self.ui.toc.getTocTitleByPage, self.ui.toc, g.pageno)
        if ok and title and title ~= "" then g.chapter = title end
    end
    self:notesChanged()
    self:hideChip(false)
    self:save()
    self:repaint()
    self:log(g)
end

function Ink:log(g)
    local f = io.open(self.log_path, "a")
    if not f then return end
    local title = self.ui.doc_props and self.ui.doc_props.display_title or "?"
    f:write(T("## %1 — %2, p. %3\n\n**Me:** %4\n\n**AI:** %5\n\n",
        os.date("%Y-%m-%d %H:%M"), title, self.book:currentPage() or "?", g.question or "(ink)",
        g.note .. (g.more and ("\n\n" .. g.more) or "")))
    f:close()
end

-- "Ask AI" in the popup of selected text.
function Ink:askSelection(hl)
    local key, mock = self:credentials()
    if not key and not mock then
        pcall(hl.onClose, hl)
        return
    end
    pcall(hl.highlightFromHoldPos, hl)
    local sel = hl.selected_text
    if not (sel and sel.pos0 and sel.pos1 and sel.text) then return end
    local g = { id = newId(), created = os.time(), selected_text = util.cleanupSelectedText(sel.text) }
    local ok = self.book:anchorSelection(g, sel)
    pcall(hl.onClose, hl)
    if not ok then return end
    table.insert(self.data.groups, g)
    self:save()
    UIManager:nextTick(guarded(function() self:ask(g) end))
end

------------------------------------------------------------------------------
-- A note, opened
------------------------------------------------------------------------------

function Ink:openAnswer(g)
    local View = require("glossator/view")
    local view = View:new{
        group = g,
        px = self:notePx(),
        hand = self:hand(),
        pad_path = self.pad_path,
        on_ask = function(v, req) self:askReply(g, v, req) end,
        on_type = function() self:typeFollowUp(g) end,
        on_delete = function(with_ink) self:deleteGroup(g, with_ink) end,
        on_close = function(v) if self.open_view == v then self.open_view = nil end end,
    }
    self.open_view = view
    UIManager:show(view)
    return view
end

-- A typed follow-up: the question dialog on its own over the page, with the
-- on-screen keyboard; then the note opens again, waiting for the answer.
function Ink:typeFollowUp(g)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Follow-up question"),
        input_hint = _("Type your question"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
                self:openAnswer(g)
            end },
            { text = _("Ask"), is_enter_default = true, callback = function()
                local q = dialog:getInputText()
                UIManager:close(dialog)
                local view = self:openAnswer(g)
                if q and q:match("%S") then view:ask({ typed = q }) end
            end },
        }},
    }
    self:showWithKeyboard(dialog)
end

-- Show a text dialog with the on-screen keyboard up, and keep it up. KOReader
-- hides the keyboard at any tap outside it (and closes the dialog at a tap
-- outside that), so the hand resting on the glass, or the tail of the pen tap
-- that opened the dialog, could put it away at once. The dialog is shown once
-- that tap is over, keeps its keyboard, and the keyboard is brought back if
-- something hid it all the same.
function Ink:showWithKeyboard(dialog)
    dialog.deny_keyboard_hiding = true
    UIManager:nextTick(guarded(function()
        UIManager:show(dialog)
        dialog:onShowKeyboard()
        UIManager:scheduleIn(0.6, guarded(function()
            if UIManager:isWidgetShown(dialog) and dialog.isKeyboardVisible and not dialog:isKeyboardVisible() then
                dialog:onShowKeyboard()
            end
        end))
    end))
end

-- A follow-up asked in the opened note (written on its pad, or typed): the
-- answer joins the note's conversation (g.replies), shown in the same card.
function Ink:askReply(g, view, req)
    local key, mock = self:credentials()
    if not key and not mock then
        view:answered(_("No API key."))
        return
    end
    if self.job then
        view:answered(_("Still answering the last question."))
        return
    end
    local function go()
        local lines = { self:pageContext() }
        if req.typed then
            table.insert(lines, "This is a follow-up in a conversation about a note you wrote in the margin. The user typed:\n\"\"\"\n"
                .. req.typed .. "\n\"\"\"\nAnswer it; in <transcription> put the question.")
        else
            table.insert(lines, "This is a follow-up in a conversation about a note you wrote in the margin. The image is the user's handwritten follow-up question; transcribe it and answer it.")
        end
        self:runJob({
            cred = key, mock = mock,
            images = req.image and { req.image } or {},
            context = table.concat(lines, "\n\n"),
            history = self:conversationOf(g),
        }, function(res, err)
            if req.image then os.remove(req.image) end
            if not res then
                if view then view:answered(tostring(err)) end
                return
            end
            g.replies = g.replies or {}
            table.insert(g.replies, { question = req.typed or res.transcription, note = res.note, more = res.more, created = os.time() })
            self:save()
            self:notesChanged()
            self:log({ question = req.typed or res.transcription, note = res.note, more = res.more })
            if view then view:answered() end
            self:repaint()
        end)
    end
    if mock then go() else NetworkMgr:runWhenOnline(go) end
end

-- The conversation of a note so far, for a follow-up: what was asked and
-- answered, oldest first (including notes it follows, from older versions).
function Ink:conversationOf(g)
    local out = self:threadOf(g)
    if g.note then
        table.insert(out, { question = g.question or g.selected_text or "(ink on the page)", answer = g.note .. (g.more and ("\n\n" .. g.more) or "") })
    end
    for _i, r in ipairs(g.replies or {}) do
        table.insert(out, { question = r.question, answer = r.note .. (r.more and ("\n\n" .. r.more) or "") })
    end
    while #out > THREAD_MAX * 2 do table.remove(out, 1) end
    return out
end

function Ink:deleteGroup(g, with_ink)
    self:edit(function()
        for i, o in ipairs(self.data.groups) do
            if o == g then
                if with_ink or #(g.strokes or {}) == 0 then
                    table.remove(self.data.groups, i)
                else
                    g.note, g.more, g.question, g.status = nil, nil, nil, nil
                end
                break
            end
        end
    end)
    if self.fresh == g then self.fresh = nil end
    self:notesChanged()
    self:hideChip(false)
    self:repaint()
end

-- Fetch OpenRouter's newest vision models (a few from each big provider) for
-- the "More models" menu.
function Ink:refreshModels()
    if self.job then
        UIManager:show(Notification:new{ text = _("Still answering the last question.") })
        return
    end
    NetworkMgr:runWhenOnline(function()
        UIManager:show(Notification:new{ text = _("Getting the model list\u{2026}") })
        self:runJob({ task = "models" }, function(res, err)
            if type(res) ~= "table" or #res == 0 then
                UIManager:show(InfoMessage:new{ text = tostring(err or _("No models found.")) })
                return
            end
            local list = {}
            for _i, m in ipairs(res) do table.insert(list, { id = m.id, name = m.name }) end
            G_reader_settings:saveSetting("glossator_more_models", list)
            UIManager:show(InfoMessage:new{ text = T(_("%1 models from OpenRouter are in Model → More models."), #list), timeout = 4 })
        end)
    end)
end

function Ink:typeModelId()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    local cur = self:getModel():match("^openrouter:(.+)$") or ""
    dialog = InputDialog:new{
        title = _("OpenRouter model ID"),
        input = cur,
        input_hint = "google/gemini-3.8-flash",
        description = _("Any model on openrouter.ai/models that reads images."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Use it"), is_enter_default = true, callback = function()
                local id = (dialog:getInputText() or ""):gsub("%s", "")
                UIManager:close(dialog)
                if id ~= "" then G_reader_settings:saveSetting("inkai_model", "openrouter:" .. id) end
            end },
        }},
    }
    self:showWithKeyboard(dialog)
end

-- Ask about the whole page, without ink: the answer opens as a note. It runs
-- in the background like any question.
function Ink:explainPage()
    if self.job then
        UIManager:show(Notification:new{ text = _("Still answering the last question.") })
        return
    end
    local key, mock = self:credentials()
    if not key and not mock then return end
    local function go()
        self.shooting = true
        self:repaint()
        UIManager:forceRePaint()
        self:writeImages(nil)
        self.shooting = false
        self:repaint(self.toolbar.rect)
        UIManager:show(Notification:new{ text = _("Reading the page\u{2026}") })
        self:runJob({
            cred = key, images = { self.page_path }, mock = mock,
            context = self:pageContext() .. "\n\nThere is no ink: explain the key idea of this page as a margin note, and use <more> for a short walk-through.",
        }, function(res, err)
            if not res then
                UIManager:show(InfoMessage:new{ text = tostring(err) })
                return
            end
            local g = { id = "page", note = res.note, more = res.more, question = _("Explain this page") }
            local View = require("glossator/view")
            UIManager:show(View:new{ group = g, px = self:notePx(), hand = self:hand(), transient = true })
        end)
    end
    if mock then go() else NetworkMgr:runWhenOnline(go) end
end

------------------------------------------------------------------------------
-- Export
------------------------------------------------------------------------------

function Ink:pageLabel(g)
    local a = g.a or {}
    if a.page then return tostring(a.page) end
    local xp = a.xp0 or a.pxp
    if xp then
        local ok, p = pcall(self.ui.document.getPageFromXPointer, self.ui.document, xp)
        if ok and p then return tostring(p) end
    end
    return "?"
end

-- All of the book's notes as Markdown (math stays as LaTeX, which most
-- Markdown apps render).
function Ink:exportMarkdown()
    local props = self.ui.doc_props or {}
    local title = props.display_title or "Book"
    local list = {}
    for _i, g in ipairs(self.data.groups) do
        if g.note then list[#list + 1] = g end
    end
    if #list == 0 then
        UIManager:show(InfoMessage:new{ text = _("There are no AI notes in this book yet.") })
        return
    end
    table.sort(list, function(a, b)
        local pa, pb = tonumber(self:pageLabel(a)) or 0, tonumber(self:pageLabel(b)) or 0
        if pa ~= pb then return pa < pb end
        return (a.created or 0) < (b.created or 0)
    end)
    local out = { "# " .. title, "" }
    if props.authors then table.insert(out, "_" .. props.authors .. "_") table.insert(out, "") end
    table.insert(out, T("Notes from Glossator, exported %1.", os.date("%Y-%m-%d")))
    table.insert(out, "")
    for _i, g in ipairs(list) do
        table.insert(out, "## " .. T("Page %1", self:pageLabel(g)))
        table.insert(out, "")
        if g.selected_text then
            table.insert(out, "> " .. g.selected_text:gsub("\n", "\n> "))
            table.insert(out, "")
        elseif g.question and g.question ~= "" then
            table.insert(out, "> " .. g.question)
            table.insert(out, "")
        end
        table.insert(out, g.note)
        table.insert(out, "")
        if g.more then
            table.insert(out, g.more)
            table.insert(out, "")
        end
        for _i, r in ipairs(g.replies or {}) do
            table.insert(out, "> " .. (r.question or "?"))
            table.insert(out, "")
            table.insert(out, r.note)
            table.insert(out, "")
            if r.more then
                table.insert(out, r.more)
                table.insert(out, "")
            end
        end
    end
    util.makePath(self.export_dir)
    local name = util.getSafeFilename(title, self.export_dir, 80) .. ".md"
    local path = self.export_dir .. "/" .. name
    local f = io.open(path, "w")
    if not f then
        UIManager:show(InfoMessage:new{ text = T(_("Could not write %1"), path) })
        return
    end
    f:write(table.concat(out, "\n"))
    f:close()
    UIManager:show(InfoMessage:new{ text = T(_("Notes saved to\n%1"), path) })
end

------------------------------------------------------------------------------
-- Menu and actions
------------------------------------------------------------------------------

function Ink:onDispatcherRegisterActions()
    Dispatcher:registerAction("glossator_toggle_pen", {
        category = "none", event = "GlossatorTogglePen", title = _("Glossator: pen writes on the page (toggle)"), reader = true,
    })
    Dispatcher:registerAction("glossator_toggle_show", {
        category = "none", event = "GlossatorToggleShow", title = _("Glossator: show ink and notes (toggle)"), reader = true,
    })
    Dispatcher:registerAction("glossator_toolbar", {
        category = "none", event = "GlossatorToolbar", title = _("Glossator: writing toolbar (toggle)"), reader = true,
    })
    Dispatcher:registerAction("glossator_explain_page", {
        category = "none", event = "GlossatorExplainPage", title = _("Glossator: explain this page"), reader = true,
    })
    Dispatcher:registerAction("glossator_undo", {
        category = "none", event = "GlossatorUndo", title = _("Glossator: undo"), reader = true,
    })
    Dispatcher:registerAction("glossator_reset", {
        category = "none", event = "GlossatorReset", title = _("Glossator: reset (if something gets stuck)"), reader = true,
    })
    Dispatcher:registerAction("glossator_menu", {
        category = "none", event = "GlossatorMenu", title = _("Glossator: quick menu"), reader = true,
    })
end

-- Put everything back to rest: no stroke, chip, selection, follow-up or
-- question in progress, and the page repainted. For when something gets stuck.
function Ink:onGlossatorReset()
    self.stroke, self.pen_tap, self.pen_hold, self.sel, self.fresh = nil, nil, nil, nil, nil
    self.pen = Stylus.new()
    self.pen_owner, self.palm_at = nil, nil
    if self.job then
        pcall(ffiutil.terminateSubProcess, self.job.pid)
        self.job = nil
    end
    for _i, g in ipairs(self.data.groups) do
        if g.status == "asking" then g.status = nil end
    end
    self:hideChip(false)
    self.toolbar.options = nil
    self.cache, self.place_cache = {}, {}
    self:detachPen()
    self:attachPen()
    UIManager:setDirty(self.ui, "full")
    UIManager:show(Notification:new{ text = _("Glossator was reset.") })
    return true
end

function Ink:onGlossatorUndo()
    self:undo()
    return true
end

function Ink:onGlossatorTogglePen()
    G_reader_settings:saveSetting("inkai_pen", not self:penOn())
    UIManager:show(Notification:new{ text = self:penOn() and _("The pen writes on the page.") or _("The pen acts as a finger.") })
    return true
end

function Ink:onGlossatorToggleShow()
    G_reader_settings:saveSetting("inkai_show", not self:shown())
    self:hideChip(false)
    self.cache = {}
    self:repaint()
    return true
end

function Ink:onGlossatorExplainPage()
    self:explainPage()
    return true
end

-- A small menu for the Kindle-style top bar's AI button.
function Ink:onGlossatorMenu()
    local dialog
    dialog = ButtonDialog:new{
        title = _("Glossator"),
        title_align = "center",
        buttons = {
            {{ text = _("Explain this page"), callback = function() UIManager:close(dialog) self:explainPage() end }},
            {{ text = self.toolbar:state() == "open" and _("Hide the writing toolbar") or _("Show the writing toolbar"),
               callback = function() UIManager:close(dialog) self:onGlossatorToolbar() end }},
            {{ text = self:shown() and _("Hide ink and notes") or _("Show ink and notes"),
               callback = function() UIManager:close(dialog) self:onGlossatorToggleShow() end }},
            {{ text = self:penOn() and _("Pen: acts as a finger") or _("Pen: writes on the page"),
               callback = function() UIManager:close(dialog) self:onGlossatorTogglePen() end }},
            {{ text = _("Export notes (Markdown)"), callback = function() UIManager:close(dialog) self:exportMarkdown() end }},
            {{ text = _("Reset (if something gets stuck)"), callback = function() UIManager:close(dialog) self:onGlossatorReset() end }},
            {{ text = _("Write with the pen anywhere on the page, then tap Ask AI."), enabled = false }},
        },
    }
    UIManager:show(dialog)
    return true
end

-- The ink and AI part of Glossator's menu (see main.lua).
function Ink:menuItems()
    local function radio(key, default, list, after)
        local items = {}
        for _i, e in ipairs(list) do
            table.insert(items, {
                text = e[2],
                radio = true,
                checked_func = function() return (G_reader_settings:readSetting(key) or default) == e[1] end,
                callback = function()
                    G_reader_settings:saveSetting(key, e[1])
                    if after then after() end
                end,
            })
        end
        return items
    end
    local function relayout()
        self.cache = {}
        self.place_cache = {}
        self:repaint()
    end
    local function modelItem(id, label)
        return {
            text = label,
            radio = true,
            checked_func = function() return self:getModel() == id end,
            callback = function() G_reader_settings:saveSetting("inkai_model", id) end,
        }
    end
    local function modelItems()
        local items = {}
        for i, m in ipairs(MODELS) do
            if m.openrouter and not (MODELS[i - 1] and MODELS[i - 1].openrouter) then
                items[#items].separator = true
                table.insert(items, { text = _("With an OpenRouter key:"), enabled = false })
            end
            table.insert(items, modelItem(m.id, m.label))
        end
        items[#items].separator = true
        table.insert(items, {
            text = _("More models (OpenRouter)"),
            sub_item_table_func = function()
                local more = {}
                for _i, m in ipairs(G_reader_settings:readSetting("glossator_more_models") or {}) do
                    table.insert(more, modelItem("openrouter:" .. m.id, m.name))
                end
                if #more > 0 then more[#more].separator = true end
                table.insert(more, {
                    text = _("Get the newest models from OpenRouter"),
                    keep_menu_open = true,
                    callback = function() self:refreshModels() end,
                })
                return more
            end,
        })
        table.insert(items, {
            text = _("Type a model ID (OpenRouter)…"),
            keep_menu_open = true,
            callback = function() self:typeModelId() end,
        })
        return items
    end
    local hands = {}
    for _i, k in ipairs({ "kalam", "caveat", "patrick" }) do table.insert(hands, { k, Fonts.HANDS[k].label }) end
    return {
            {
                text = _("Pen writes on the page"),
                checked_func = function() return self:penOn() end,
                callback = function() self:onGlossatorTogglePen() end,
            },
            {
                text = _("Show ink and notes"),
                checked_func = function() return self:shown() end,
                callback = function() self:onGlossatorToggleShow() end,
            },
            {
                text = _("Writing toolbar"),
                sub_item_table = {
                    {
                        text = _("Show the toolbar"),
                        checked_func = function() return self.toolbar:state() == "open" end,
                        callback = function() self:onGlossatorToolbar() end,
                    },
                    {
                        text = _("Keep a small tab when it is folded"),
                        checked_func = function() return self.toolbar:state() ~= "hidden" end,
                        callback = function()
                            self.toolbar:setState(self.toolbar:state() == "hidden" and "tab" or "hidden")
                            relayout()
                        end,
                    },
                    {
                        text = _("On the left edge"),
                        checked_func = function() return G_reader_settings:isTrue("inkai_toolbar_left") end,
                        callback = function()
                            G_reader_settings:flipNilOrFalse("inkai_toolbar_left")
                            relayout()
                        end,
                    },
                },
            },
            {
                text = _("Pen"),
                sub_item_table = {
                    { text = _("Width"), sub_item_table = radio("inkai_pen_width", 2,
                        { { 1, _("Fine") }, { 2, _("Medium") }, { 3, _("Bold") } }) },
                    { text = _("Eraser"), sub_item_table = radio("inkai_eraser", "stroke",
                        { { "stroke", _("Whole strokes") }, { "precise", _("Precise") } }) },
                    { text = _("Style"), sub_item_table = radio("inkai_ink_style", "pen",
                        { { "pen", _("Ink pen") }, { "pencil", _("Pencil") } }, relayout) },
                    {
                        text = _("Quick pen taps turn pages"),
                        help_text = _("A quick tap with the pen acts like a finger (turns the page, presses buttons), and holding the pen still selects text. Off: every touch of the pen is ink."),
                        checked_func = function() return self:penTapsAct() end,
                        callback = function() G_reader_settings:saveSetting("inkai_pen_taps", not self:penTapsAct()) end,
                    },
                    {
                        text = _("Ignore the hand while writing"),
                        help_text = _("While you write, and for a moment after the pen lifts or while it hovers, finger touches on the page are ignored, so a wrist or palm resting on the glass doesn't turn the page. The toolbar and the Ask AI chip still answer a finger."),
                        checked_func = function() return G_reader_settings:readSetting("glossator_palm") ~= false end,
                        callback = function()
                            G_reader_settings:saveSetting("glossator_palm", G_reader_settings:readSetting("glossator_palm") == false)
                        end,
                    },
                    {
                        text = _("Smooth strokes"),
                        checked_func = function() return G_reader_settings:readSetting("inkai_smooth") ~= false end,
                        callback = function()
                            G_reader_settings:saveSetting("inkai_smooth", G_reader_settings:readSetting("inkai_smooth") == false)
                            relayout()
                        end,
                    },
                    {
                        text = _("Keep the pen apart from the hand"),
                        help_text = _("Uses Ink Away's pen bridge: the pen's events stay on the pen's own channel, so a palm resting on the glass can't move the line or swallow the pen's lift (which joins strokes with stray lines). Takes effect when a book is opened. Leave it on unless the pen misbehaves."),
                        checked_func = function() return G_reader_settings:readSetting("glossator_bridge") ~= false end,
                        callback = function()
                            G_reader_settings:saveSetting("glossator_bridge", G_reader_settings:readSetting("glossator_bridge") == false)
                        end,
                    },
                    {
                        text = _("Pen pressure (experimental)"),
                        help_text = _("The line follows how hard you press (with \"Keep the pen apart from the hand\" on). Off: it follows the writing speed."),
                        checked_func = function() return G_reader_settings:isTrue("glossator_pressure") end,
                        callback = function() G_reader_settings:flipNilOrFalse("glossator_pressure") end,
                    },
                },
            },
            { text = _("Explain this page"), callback = function() self:explainPage() end },
            { text = _("Export notes (Markdown)"), callback = function() self:exportMarkdown() end },
            {
                text = _("Include AI notes in Export highlights"),
                help_text = _("KOReader's Export highlights (in the Tools menu) can send your highlights to Readwise, Joplin, Nextcloud Notes, Markdown, HTML and more. With this on, Glossator's notes go along: what you asked as the highlight, the answer and follow-ups as its note."),
                checked_func = function() return ExportHook.enabled() end,
                callback = function()
                    G_reader_settings:saveSetting("glossator_export_notes", not ExportHook.enabled())
                end,
            },
            { text = _("Reset (if something gets stuck)"), callback = function() self:onGlossatorReset() end, separator = true },
            { text = _("Handwriting of the notes"), sub_item_table = radio("inkai_hand", "kalam", hands, relayout) },
            { text = _("Size of the notes"), sub_item_table = radio("inkai_size", "medium",
                { { "small", _("Small") }, { "medium", _("Medium") }, { "large", _("Large") } }, relayout) },
            {
                text_func = function() return T(_("Model: %1"), self:modelLabel()) end,
                sub_item_table_func = modelItems,
                separator = true,
            },
            {
                text = _("Delete all ink and notes in this book"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete all ink and AI notes in this book?"),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            self:edit(function()
                                for i = #self.data.groups, 1, -1 do self.data.groups[i] = nil end
                            end)
                            self.fresh = nil
                            self:hideChip(false)
                            self:repaint()
                        end,
                    })
                end,
            },
    }
end

return Ink
