--[[--
Glossator's reading look and controls for KOReader's reader, after the feel of
a dedicated e-reader: calm, minimal, out of
the way. KOReader's engine and menus stay; only what you see and touch while
reading changes.

  * Tap the top of the page: a clean top bar (back to the library, Aa,
    contents, search, bookmark, AI, more) and, at the bottom, a slim
    progress bar with your place in the book. Tap the page to hide them.
  * E-reader tap zones: a narrow strip on the left goes back a page, the rest
    of the page goes forward, the bottom edge turns pages too.
  * PDFs open one whole page per screen, like a dedicated e-reader (page mode, the page
    fitted to the screen), instead of continuous scroll at full width, which
    leaves half of one page and half of the next on the screen.
  * A one-line footer ("Page 12 of 300 · 4%") in place of KOReader's status
    bar, a calmer page refresh, and the book's cover when the reader sleeps
    (each can be turned off).
  * Swiping down from the top still opens KOReader's full menu, and "More"
    in the top bar opens it as well, so nothing is lost.

Icons are this plugin's own drawings (icons/*.svg). Inspired by the feel of
a dedicated e-reader; no Amazon assets or trademarks are used.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")
local Screen = Device.screen

local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*/[^/]*$") or ".")
local ICONS = PLUGIN_DIR .. "/icons/bar/"

local TOP_ZONE = 0.09     -- the band at the top that shows the bars
local BOTTOM_ZONE = 0.07  -- the band at the bottom that turns pages
local BACK_STRIP = 0.2    -- the left strip that goes back

local floor, max, min = math.floor, math.max, math.min

local function contains(r, x, y)
    return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

------------------------------------------------------------------------------
-- The bars
------------------------------------------------------------------------------

local Bars = InputContainer:extend{
    ui = nil,
    plugin = nil,
}

function Bars:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.top_h = Screen:scaleBySize(58)
    self.bottom_h = Screen:scaleBySize(74)
    self.icon = Screen:scaleBySize(26)
    self.pad = Screen:scaleBySize(16)
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self:layout()
end

function Bars:hasAI()
    return self.ui.glossator ~= nil
end

-- The buttons of the top bar, right to left.
function Bars:buttons()
    local ui = self.ui
    local marked = false
    pcall(function() marked = ui.bookmark:isPageBookmarked() end)
    local list = {
        { id = "more", icon = "more", act = function() self:close() ui:handleEvent(Event:new("ShowMenu")) end },
    }
    if self:hasAI() then
        table.insert(list, { id = "ai", icon = "ai", act = function() self:close() ui:handleEvent(Event:new("GlossatorMenu")) end })
        table.insert(list, { id = "pen", icon = "pen", act = function() self:close() ui:handleEvent(Event:new("GlossatorToolbar")) end })
    end
    if Device:hasFrontlight() then
        table.insert(list, { id = "light", icon = "light", act = function() self:close() ui:handleEvent(Event:new("ShowFlDialog")) end })
    end
    table.insert(list, { id = "bookmark", icon = marked and "bookmark-on" or "bookmark", act = function()
        ui:handleEvent(Event:new("ToggleBookmark"))
        self:layout()
        UIManager:setDirty(self, "ui", Geom:new(self.top_rect))
    end })
    table.insert(list, { id = "search", icon = "search", act = function() self:close() ui:handleEvent(Event:new("ShowFulltextSearchInput")) end })
    table.insert(list, { id = "contents", icon = "contents", act = function() self:close() ui:handleEvent(Event:new("ShowToc")) end })
    table.insert(list, { id = "aa", icon = "aa", act = function() self:close() ui:handleEvent(Event:new("ShowConfigMenu")) end })
    return list
end

function Bars:layout()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.top_rect = { x = 0, y = 0, w = W, h = self.top_h }
    self.bottom_rect = { x = 0, y = H - self.bottom_h, w = W, h = self.bottom_h }
    -- top: back on the left, icons on the right
    self.hits = {}
    local s = self.icon
    local cy = floor((self.top_h - s) / 2)
    local x = W - self.pad - s
    self.icons = {}
    local slot = s + Screen:scaleBySize(18)
    for _i, b in ipairs(self:buttons()) do
        table.insert(self.icons, { file = ICONS .. b.icon .. ".svg", x = x, y = cy })
        table.insert(self.hits, { rect = { x = x - floor((slot - s) / 2), y = 0, w = slot, h = self.top_h }, act = b.act })
        x = x - slot
    end
    self.icons_left = x + slot - Screen:scaleBySize(10)
    local back_w = Screen:scaleBySize(130)
    table.insert(self.hits, { rect = { x = 0, y = 0, w = back_w, h = self.top_h }, act = function()
        self:close()
        self.ui:handleEvent(Event:new("Home"))
    end })
    self.back_w = back_w
    -- bottom: progress bar
    local ph = Screen:scaleBySize(30)
    self.track = { x = self.pad * 2, y = H - self.bottom_h + Screen:scaleBySize(40), w = W - self.pad * 4, h = ph }
end

function Bars:progress()
    local ui = self.ui
    local ok, page = pcall(ui.getCurrentPage, ui)
    page = ok and page or 1
    local total = ui.document:getPageCount() or 1
    local pct = total > 1 and (page - 1) / (total - 1) or 1
    if page >= total then pct = 1 end
    local chapter
    pcall(function() chapter = ui.toc:getTocTitleOfCurrentPage() end)
    return page, total, pct, chapter
end

local function face(name, size)
    return Font:getFace(name, size)
end

function Bars:text(bb, x, baseline, f, s, color, max_w)
    if max_w then s = RenderText:truncateTextByWidth(s, f, max_w) end
    RenderText:renderUtf8Text(bb, x, baseline, f, s, true, false, color or Blitbuffer.COLOR_BLACK)
    return RenderText:sizeUtf8Text(0, nil, f, s, true).x
end

function Bars:paintIcon(bb, file, x, y)
    local ok, img = pcall(function()
        return ImageWidget:new{ file = file, width = self.icon, height = self.icon, alpha = true }
    end)
    if ok and img then
        img:paintTo(bb, x, y)
        img:free()
    end
end

function Bars:paintTo(bb, ox, oy)
    local ok, err = pcall(self.paintUnsafe, self, bb, ox, oy)
    if not ok then logger.err("Look: bars:", err) end
end

function Bars:paintUnsafe(bb, ox, oy)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local hair = max(1, Screen:scaleBySize(1))
    -- top bar
    bb:paintRect(ox, oy, W, self.top_h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(ox, oy + self.top_h - hair, W, hair, Blitbuffer.COLOR_GRAY_B)
    local s = self.icon
    local cy = floor((self.top_h - s) / 2)
    self:paintIcon(bb, ICONS .. "back.svg", ox + self.pad - Screen:scaleBySize(4), oy + cy)
    local lf = face("cfont", 16)
    local m = RenderText:sizeUtf8Text(0, nil, lf, "Lg", true)
    local base = oy + floor((self.top_h + m.y_top - m.y_bottom) / 2)
    self:text(bb, ox + self.pad + s, base, lf, _("Library"))
    for _i, ic in ipairs(self.icons) do self:paintIcon(bb, ic.file, ox + ic.x, oy + ic.y) end
    -- the title, centred in what is left
    local props = self.ui.doc_props or {}
    local title = props.display_title or ""
    local tf = face("cfont", 15)
    local left = self.back_w + self.pad
    local avail = self.icons_left - left
    if avail > Screen:scaleBySize(60) and title ~= "" then
        local tw = min(RenderText:sizeUtf8Text(0, nil, tf, title, true).x, avail)
        local tx = max(left, floor((W - tw) / 2))
        if tx + tw > self.icons_left then tx = left end
        self:text(bb, ox + tx, base, tf, title, Blitbuffer.COLOR_GRAY_4, avail)
    end
    -- bottom bar
    local by = oy + H - self.bottom_h
    bb:paintRect(ox, by, W, self.bottom_h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(ox, by, W, hair, Blitbuffer.COLOR_GRAY_B)
    local page, total, pct, chapter = self:progress()
    local sf = face("cfont", 13)
    local sm = RenderText:sizeUtf8Text(0, nil, sf, "Lg", true)
    local line = by + Screen:scaleBySize(10) + sm.y_top
    local right = T(_("Page %1 of %2 · %3%"), page, total, floor(pct * 100 + 0.5))
    local rw = RenderText:sizeUtf8Text(0, nil, sf, right, true).x
    self:text(bb, ox + W - self.pad * 2 - rw, line, sf, right, Blitbuffer.COLOR_GRAY_3)
    if chapter and chapter ~= "" then
        self:text(bb, ox + self.pad * 2, line, sf, chapter, Blitbuffer.COLOR_GRAY_5, W - rw - self.pad * 6)
    end
    -- the track: a hairline, the part read a little heavier, and a knob
    local t = self.track
    local mid = by + (t.y - (H - self.bottom_h)) + floor(t.h / 2)
    bb:paintRect(ox + t.x, mid, t.w, hair, Blitbuffer.COLOR_GRAY_9)
    local done = floor(t.w * pct)
    local thick = max(2, Screen:scaleBySize(3))
    bb:paintRect(ox + t.x, mid - floor(thick / 2), done, thick, Blitbuffer.COLOR_BLACK)
    local r = Screen:scaleBySize(7)
    bb:paintCircle(ox + t.x + done, mid, r, Blitbuffer.COLOR_BLACK)
end

function Bars:onShow()
    UIManager:setDirty(self, "ui", Geom:new(self.top_rect))
    UIManager:setDirty(self, "ui", Geom:new(self.bottom_rect))
end

function Bars:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self)
    UIManager:setDirty(self.ui, "ui", Geom:new(self.top_rect))
    UIManager:setDirty(self.ui, "ui", Geom:new(self.bottom_rect))
end

function Bars:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    if contains(self.top_rect, x, y) then
        for _i, h in ipairs(self.hits) do
            if contains(h.rect, x, y) then
                h.act()
                return true
            end
        end
        return true
    end
    if contains(self.bottom_rect, x, y) then
        local t = self.track
        if x >= t.x - self.pad and x <= t.x + t.w + self.pad and y >= self.bottom_rect.y + Screen:scaleBySize(24) then
            local pct = min(1, max(0, (x - t.x) / t.w))
            local total = self.ui.document:getPageCount() or 1
            if self.ui.paging then
                self.ui:handleEvent(Event:new("GotoPage", max(1, floor(pct * (total - 1) + 1.5))))
            else
                self.ui:handleEvent(Event:new("GotoPercent", pct * 100))
            end
            UIManager:setDirty(self, "ui", Geom:new(self.bottom_rect))
        end
        return true
    end
    self:close()
    return true
end

function Bars:onSwipe()
    self:close()
    return true
end

function Bars:onHold()
    return true
end

function Bars:onCloseWidget()
    self.plugin.bars = nil
end

------------------------------------------------------------------------------
-- The plugin
------------------------------------------------------------------------------

local Look = WidgetContainer:extend{
    name = "glossator_look",
}

function Look:init()
    self.ui.view:registerViewModule("kindleui_footer", {
        paintTo = function(_, bb, x, y) self:paintFooter(bb, x, y) end,
    })
end

local function opt(key)
    return G_reader_settings:readSetting(key) ~= false
end

-- One whole page per screen for PDFs, like a dedicated e-reader: page mode, not
-- continuous scroll, and the page fitted to the screen (optionally with its
-- white margins trimmed).
function Look:applyFullPage()
    if not (self.ui.paging and self:enabled() and opt("kindleui_full_page")) then return end
    local view = self.ui.view
    if view.page_scroll then
        self.ui:handleEvent(Event:new("SetScrollMode", false))
    end
    local want = G_reader_settings:isTrue("kindleui_trim_margins") and "content" or "page"
    local zooming = self.ui.zooming
    if zooming and zooming.zoom_mode ~= want then
        self.ui:handleEvent(Event:new("SetZoomMode", want))
    end
end

-- The one-line footer, and KOReader's own status bar hidden while it shows.
function Look:footerOn()
    return self:enabled() and opt("kindleui_footer")
end

function Look:applyFooter()
    local footer = self.ui.view and self.ui.view.footer
    if not (footer and footer.applyFooterMode) then return end
    if self:footerOn() then
        footer:applyFooterMode(footer.mode_list.off)
    else
        local mode = G_reader_settings:readSetting("reader_footer_mode")
        if mode and mode ~= footer.mode_list.off then footer:applyFooterMode(mode) end
    end
end

function Look:paintFooter(bb, x, y)
    -- a mistake here must never stop the reader from drawing its pages
    local ok, err = pcall(self.paintFooterUnsafe, self, bb, x, y)
    if not ok then logger.err("Look: footer:", err) end
end

function Look:paintFooterUnsafe(bb, x, y)
    if not self:footerOn() or self.bars then return end
    local ui = self.ui
    local ok, page = pcall(ui.getCurrentPage, ui)
    if not ok or not page then return end
    local total = ui.document:getPageCount() or 1
    local pct = floor(((total > 1) and (page - 1) / (total - 1) or 1) * 100 + 0.5)
    local text = T(_("Page %1 of %2 · %3%"), page, total, pct)
    local f = face("cfont", 11)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local m = RenderText:sizeUtf8Text(0, nil, f, text, true)
    local base = y + H - Screen:scaleBySize(10)
    -- a white band, so the text stays readable over a page that runs to the edge
    bb:paintRect(x + floor((W - m.x) / 2) - 8, base - m.y_top - 4, m.x + 16, m.y_top + m.y_bottom + 8, Blitbuffer.COLOR_WHITE)
    RenderText:renderUtf8Text(bb, x + floor((W - m.x) / 2), base, f, text, true, false, Blitbuffer.COLOR_GRAY_5)
end

-- Calm page turns: no flash on every page, a clean-up flash now and then.
Look.REFRESH = { { 1, _("Every page") }, { 6, _("Every 6 pages") }, { 20, _("Every 20 pages") }, { 0, _("Never") } }

function Look:applyRefresh()
    local rate = G_reader_settings:readSetting("kindleui_refresh")
    if rate then UIManager:setRefreshRate(rate, rate) end
end

function Look:applySleepCover()
    if not self:enabled() then return end
    if opt("kindleui_sleep_cover") and G_reader_settings:readSetting("screensaver_type") ~= "cover" then
        if G_reader_settings:hasNot("kindleui_saved_screensaver") then
            G_reader_settings:saveSetting("kindleui_saved_screensaver", G_reader_settings:readSetting("screensaver_type") or "disable")
        end
        G_reader_settings:saveSetting("screensaver_type", "cover")
    end
end

function Look:restoreSleep()
    local saved = G_reader_settings:readSetting("kindleui_saved_screensaver")
    if saved then
        G_reader_settings:saveSetting("screensaver_type", saved)
        G_reader_settings:delSetting("kindleui_saved_screensaver")
    end
end

function Look:enabled()
    return G_reader_settings:readSetting("kindleui_enabled") ~= false
end

-- E-reader page-turn zones (KOReader's own setting), keeping what was there.
function Look:applyTapZones(on)
    local saved = G_reader_settings:readSetting("kindleui_saved_zones")
    if on then
        if not saved then
            G_reader_settings:saveSetting("kindleui_saved_zones", {
                type = G_reader_settings:readSetting("page_turns_tap_zones") or "default",
                fwd = G_reader_settings:readSetting("page_turns_tap_zone_forward_size_ratio"),
                back = G_reader_settings:readSetting("page_turns_tap_zone_backward_size_ratio"),
            })
        end
        G_reader_settings:saveSetting("page_turns_tap_zones", "left_right")
        G_reader_settings:saveSetting("page_turns_tap_zone_backward_size_ratio", BACK_STRIP)
        G_reader_settings:saveSetting("page_turns_tap_zone_forward_size_ratio", 1 - BACK_STRIP)
    elseif saved then
        G_reader_settings:saveSetting("page_turns_tap_zones", saved.type)
        G_reader_settings:saveSetting("page_turns_tap_zone_forward_size_ratio", saved.fwd)
        G_reader_settings:saveSetting("page_turns_tap_zone_backward_size_ratio", saved.back)
        G_reader_settings:delSetting("kindleui_saved_zones")
    end
    pcall(function() self.ui.view:setupTouchZones() end)
end

function Look:zones()
    return {
        {
            id = "kindleui_top",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = TOP_ZONE },
            overrides = { "readermenu_tap", "readermenu_ext_tap", "tap_forward", "tap_backward",
                "readerconfigmenu_tap", "readerconfigmenu_ext_tap" },
            handler = function() return self:showBars() end,
        },
        {
            id = "kindleui_bottom",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 1 - BOTTOM_ZONE, ratio_w = 1, ratio_h = BOTTOM_ZONE },
            overrides = { "readerconfigmenu_tap", "readerconfigmenu_ext_tap", "readerfooter_tap",
                "tap_forward", "tap_backward" },
            handler = function(ges) return self:turn(ges) end,
        },
        {
            -- KOReader's taller middle bands at the top and bottom open its menus; on a
            -- dedicated e-reader they just turn the page
            id = "kindleui_turn",
            ges = "tap",
            screen_zone = { ratio_x = 0.25, ratio_y = TOP_ZONE, ratio_w = 0.5, ratio_h = 1 - TOP_ZONE - BOTTOM_ZONE },
            overrides = { "readermenu_ext_tap", "readerconfigmenu_ext_tap" },
            handler = function(ges) return self:turn(ges) end,
        },
    }
end

function Look:onReaderReady()
    if G_reader_settings:hasNot("kindleui_refresh") and self:enabled() then
        G_reader_settings:saveSetting("kindleui_refresh", 20)
    end
    self:applyRefresh()
    if not self:enabled() then return end
    self:applyTapZones(true)
    self.ui:registerTouchZones(self:zones())
    self:applyFullPage()
    self:applyFooter()
    self:applySleepCover()
end

function Look:setEnabled(on)
    G_reader_settings:saveSetting("kindleui_enabled", on)
    self:applyTapZones(on)
    if on then
        self.ui:registerTouchZones(self:zones())
        self:applyFullPage()
        self:applySleepCover()
    else
        self.ui:unRegisterTouchZones(self:zones())
        self:restoreSleep()
    end
    self:applyFooter()
    UIManager:setDirty(self.ui, "ui")
end

function Look:toggle(key, apply)
    G_reader_settings:saveSetting(key, not opt(key))
    if apply then apply() end
    UIManager:setDirty(self.ui, "ui")
end

function Look:turn(ges)
    -- a tap on a highlight or a link is still that
    for _i, m in ipairs({ self.ui.highlight, self.ui.link }) do
        if m and m.onTap then
            local ok, r = pcall(m.onTap, m, nil, ges)
            if ok and r then return true end
        end
    end
    local back = ges.pos.x < Screen:getWidth() * BACK_STRIP
    if self.ui.view.inverse_reading_order then back = not back end
    self.ui:handleEvent(Event:new("GotoViewRel", back and -1 or 1))
    return true
end

function Look:showBars()
    if self.bars then return true end
    self.bars = Bars:new{ ui = self.ui, plugin = self }
    UIManager:show(self.bars)
    return true
end

function Look:onCloseDocument()
    if self.bars then self.bars:close() end
end

-- The reading look part of Glossator's menu (see main.lua).
function Look:menuItems()
    local refresh = {}
    for _i, r in ipairs(Look.REFRESH) do
        table.insert(refresh, {
            text = r[2],
            radio = true,
            checked_func = function() return (G_reader_settings:readSetting("kindleui_refresh") or 6) == r[1] end,
            callback = function()
                G_reader_settings:saveSetting("kindleui_refresh", r[1])
                self:applyRefresh()
            end,
        })
    end
    return {
            {
                text = _("Top bar, progress bar and tap zones"),
                help_text = _("Tap the top of the page for a clean top bar and a progress bar. The left fifth of the page goes back, the rest goes forward. Swipe down from the top for KOReader's full menu."),
                checked_func = function() return self:enabled() end,
                callback = function() self:setEnabled(not self:enabled()) end,
            },
            {
                text = _("PDF: one whole page per screen"),
                help_text = _("Page mode with the page fitted to the screen, one whole page per tap. Off: KOReader's own view settings (continuous scroll, zoom) are left alone."),
                enabled_func = function() return self:enabled() end,
                checked_func = function() return opt("kindleui_full_page") end,
                callback = function() self:toggle("kindleui_full_page", function() self:applyFullPage() end) end,
            },
            {
                text = _("PDF: trim the white margins"),
                help_text = _("Fit the page's text block instead of the whole page: bigger text, less room for notes."),
                enabled_func = function() return self:enabled() and opt("kindleui_full_page") end,
                checked_func = function() return G_reader_settings:isTrue("kindleui_trim_margins") end,
                callback = function()
                    G_reader_settings:flipNilOrFalse("kindleui_trim_margins")
                    self:applyFullPage()
                end,
            },
            {
                text = _("One-line footer"),
                enabled_func = function() return self:enabled() end,
                checked_func = function() return opt("kindleui_footer") end,
                callback = function() self:toggle("kindleui_footer", function() self:applyFooter() end) end,
            },
            {
                text = _("Book cover when asleep"),
                enabled_func = function() return self:enabled() end,
                checked_func = function() return opt("kindleui_sleep_cover") end,
                callback = function()
                    self:toggle("kindleui_sleep_cover", function()
                        if opt("kindleui_sleep_cover") then self:applySleepCover() else self:restoreSleep() end
                    end)
                end,
            },
            { text = _("Full refresh (flash)"), sub_item_table = refresh },
    }
end

return Look
