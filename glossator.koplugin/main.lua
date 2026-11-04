--[[--
Glossator: a reading companion for KOReader on pen e-readers.

A glossator was a medieval scholar who wrote explanations ("glosses") in the
margins of books. This plugin does that with Claude: write or circle on the
page with the pen, tap Ask AI, and the answer is handwritten into the margin
next to your ink, with real math. It also gives the reader a calm e-reader
look: a clean top bar and progress bar, one whole PDF page per screen,
e-reader tap zones.

Two parts, one plugin:
  glossator/ink.lua   the pen, the writing toolbar, asking Claude, the notes
  glossator/look.lua  the top bar, progress bar, footer, tap zones, PDF view

Setup: put your Anthropic API key (one line) in koreader/glossator_key.txt.
]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local Ink = require("glossator/ink")
local Look = require("glossator/look")

local Glossator = WidgetContainer:extend{
    name = "glossator",
    is_doc_only = true,
}

function Glossator:init()
    self.ink = Ink:new{ ui = self.ui, plugin = self }
    self.look = Look:new{ ui = self.ui, plugin = self }
    self.ui.menu:registerToMainMenu(self)
end

-- KOReader's events go to both parts. Each is guarded: a mistake in one must
-- never break the reader or the other part.
function Glossator:handleEvent(event)
    local handled = false
    for _i, part in ipairs({ self.ink, self.look }) do
        local ok, r = pcall(part.handleEvent, part, event)
        if not ok then
            logger.err("Glossator:", event.handler, r)
        elseif r then
            handled = true
        end
    end
    if event.handler == "onReaderReady" then self:checkOldPlugins() end
    return handled
end

-- Glossator replaces Ink AI and the Kindle look plugins; with them installed
-- too, two plugins would draw ink and handle taps.
function Glossator:checkOldPlugins()
    local old = {}
    if self.ui.inkai then table.insert(old, "inkai.koplugin") end
    if self.ui.kindleui then table.insert(old, "kindleui.koplugin") end
    if #old == 0 then return end
    UIManager:show(InfoMessage:new{
        text = _("Glossator replaces these older plugins. Please delete them from koreader/plugins/ and restart KOReader:") .. "\n\n" .. table.concat(old, "\n"),
    })
end

function Glossator:addToMainMenu(menu_items)
    menu_items.glossator = {
        text = _("Glossator"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return {
                { text = _("Writing and AI"), sub_item_table_func = function() return self.ink:menuItems() end },
                { text = _("Reading look"), sub_item_table_func = function() return self.look:menuItems() end },
            }
        end,
    }
end

return Glossator
