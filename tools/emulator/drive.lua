--[[
Emulator driver (a KOReader user patch, never installed on the device).
Plays the scenario named by $INKAI_SCENARIO: a Lua file returning a list of
steps, each a function(api) run after `wait` seconds. The api simulates the
pen through KOReader's real stylus callback (as the Scribe's Wacom pen
arrives), finger taps through the gesture path, and takes screenshots.
]]
local scen = os.getenv("INKAI_SCENARIO")
if not scen then return end
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local Screen = Device.screen
local shots = os.getenv("INKAI_SHOTS") or "."

local api = {}

-- A pen stroke through the stylus callback: points {x1, y1, x2, y2, ...}.
function api.pen(points, tool)
    local inp = Device.input
    local cb = inp.stylus_callback
    if not cb then logger.warn("drive: no stylus callback") return end
    local t = time.now()
    for i = 1, #points, 2 do
        t = t + time.ms(8)
        cb(inp, { slot = 0, id = 0, x = points[i], y = points[i + 1], tool = tool or 1, timev = t })
    end
    cb(inp, { slot = 0, id = -1, x = points[#points - 1], y = points[#points], tool = tool or 1, timev = t + time.ms(8) })
end

-- A hand-drawn ellipse around (cx, cy).
function api.circle(cx, cy, rx, ry, wobble)
    local pts = {}
    local n = 60
    for i = 0, n + 4 do
        local a = (i / n) * 2 * math.pi - 0.6
        local w = 1 + (wobble or 0.04) * math.sin(i * 0.7)
        pts[#pts + 1] = math.floor(cx + rx * w * math.cos(a))
        pts[#pts + 1] = math.floor(cy + ry * w * math.sin(a))
    end
    return pts
end

-- Handwriting-ish: a polyline per letter stroke, scaled and moved.
function api.scribble(strokes, ox, oy, s)
    for _, st in ipairs(strokes) do
        local pts = {}
        for i = 1, #st, 2 do
            pts[#pts + 1] = math.floor(ox + st[i] * s)
            pts[#pts + 1] = math.floor(oy + st[i + 1] * s)
        end
        api.pen(pts)
    end
end

function api.tap(x, y)
    local ges = { ges = "tap", pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, time = time.now() }
    UIManager:sendEvent(Event:new("Gesture", ges))
end

function api.event(name, ...)
    local ui = require("apps/reader/readerui").instance
    if ui then ui:handleEvent(Event:new(name, ...)) end
end

function api.shot(name)
    UIManager:forceRePaint()
    Screen:shot(shots .. "/" .. name .. ".png")
    logger.info("drive: shot", name)
end

function api.ui()
    return require("apps/reader/readerui").instance
end

function api.plugin(name)
    local ui = api.ui()
    if not ui then return nil end
    -- Glossator's two parts, by the names they had as separate plugins
    if name == "inkai" then return ui.glossator and ui.glossator.ink end
    if name == "kindleui" then return ui.glossator and ui.glossator.look end
    return ui[name]
end

api.UIManager = UIManager
api.Screen = Screen
api.Event = Event

local steps = dofile(scen)
local i = 0
local function run()
    i = i + 1
    local step = steps[i]
    if not step then
        logger.info("drive: done")
        UIManager:scheduleIn(0.5, function() UIManager:quit() os.exit(0) end)
        return
    end
    UIManager:scheduleIn(step.wait or 1, function()
        logger.info("drive: step", i)
        local ok, err = pcall(step[1] or step.run, api)
        if not ok then logger.warn("drive: step", i, "failed:", err) end
        run()
    end)
end
UIManager:scheduleIn(3, run)
