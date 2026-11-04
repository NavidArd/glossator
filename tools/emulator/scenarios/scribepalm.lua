-- A hand resting on a Kindle Scribe's glass while the pen writes, replayed
-- through KOReader's real Input (evdev frames from two devices: the Wacom pen
-- and the touch panel, into one Input, as on the Scribe) into Glossator's real
-- pen code. After Ink Away's tests/scribe harness (MIT).
--
-- Each case is run with the pen bridge (Glossator's default) and without it;
-- without it the old lines-all-over bug should show. Results in scribepalm.txt.
local Device = require("device")
local ffi = require("ffi")
require("ffi/linux_input_h")
local C = ffi.C
local K, A = C.EV_KEY, C.EV_ABS
local Input = require("device/input")

local PEN_FD, PANEL_FD = 10, 11
-- stroke A top-left, stroke B bottom, the palm in between
local AX0, AY0 = 300, 500
local BX0, BY0 = 500, 1900
local function region(x, y)
  if y < 800 then return "A" end
  if y > 1700 then return "B" end
  if x > 800 and x < 1200 and y > 1000 and y < 1500 then return "P" end
  return "-"
end

local log = {}
local function out(s) table.insert(log, s) end

local function newWorld(ink, bridge)
  G_reader_settings:saveSetting("glossator_bridge", bridge)
  local fakeDevice = { screen = Device.screen,
    isSDL = function() return false end, isAndroid = function() return false end,
    isPocketBook = function() return false end, isRemarkable = function() return false end }
  local input = Input:new{ device = fakeDevice, input = {}, event_map = {}, group = { Back = {} } }
  input.wacom_protocol = true
  -- a book was opened: KOReader paused input and resumed it
  input:inhibitInput(true); input:inhibitInput(false)
  local w = { input = input, strokes = {}, T = os.time(), panel_last_slot = nil, panel_tool = {}, ges = {} }
  -- plug Glossator's pen into this Input, as it does into the real one
  ink:detachPen()
  w.real_input = Device.input
  Device.input = input
  ink:attachPen()
  ink.prev_cb = nil
  w.bridged = ink.bridge ~= nil
  w.palm_passed = 0
  local cb = input.stylus_callback
  input.stylus_callback = function(inp, slot)
    local r = cb(inp, slot)
    if slot.tool == 2 and slot.slot ~= inp.pen_slot and not r then w.palm_passed = w.palm_passed + 1 end
    return r
  end
  local endStroke = ink.endStroke
  ink.endStroke = function(self)
    local s = self.stroke
    if s and s.tool then
      local pts = {}
      for i = 1, #s do pts[i] = s[i] end
      table.insert(w.strokes, pts)
    end
    return endStroke(self)
  end
  w.restore = function()
    ink.endStroke = nil -- back to the class method
    ink:detachPen()
    Device.input = w.real_input
    ink:attachPen()
    G_reader_settings:delSetting("glossator_bridge")
  end
  function w.frame(fd, evs, dt_ms)
    w.T = w.T + (dt_ms or 7) / 1000
    local sec = math.floor(w.T)
    local usec = math.floor((w.T - sec) * 1e6 + 0.5)
    evs[#evs + 1] = { C.EV_SYN, C.SYN_REPORT, 0 }
    for _i, e in ipairs(evs) do
      local ev = { type = e[1], code = e[2], value = e[3], time = { sec = sec, usec = usec }, fd = fd }
      input:eventAdjustHook(ev)
      if ev.type == C.EV_KEY then
        input:handleKeyBoardEv(ev)
      elseif ev.type == C.EV_ABS or ev.type == C.EV_SYN then
        for _j, g in ipairs(input:handleTouchEv(ev) or {}) do
          local ges = g.args and g.args[1]
          if ges then table.insert(w.ges, ges.ges) end
        end
      end
    end
  end
  return w
end

local pen, panel = {}, {}
function pen.enter(w, x, y, dt) w.frame(PEN_FD, { {K, C.BTN_TOOL_PEN, 1}, {A, C.ABS_X, x}, {A, C.ABS_Y, y} }, dt) end
function pen.hover(w, x, y, dt) w.frame(PEN_FD, { {A, C.ABS_X, x}, {A, C.ABS_Y, y} }, dt) end
function pen.touch(w, x, y, dt) w.frame(PEN_FD, { {K, C.BTN_TOUCH, 1}, {A, C.ABS_X, x}, {A, C.ABS_Y, y}, {A, C.ABS_PRESSURE, 900} }, dt) end
function pen.move(w, x, y, dt) w.frame(PEN_FD, { {A, C.ABS_X, x}, {A, C.ABS_Y, y}, {A, C.ABS_PRESSURE, 1000 + (math.floor(w.T * 1000) % 7)} }, dt) end
function pen.lift(w, dt) w.frame(PEN_FD, { {K, C.BTN_TOUCH, 0}, {A, C.ABS_PRESSURE, 0} }, dt) end
function pen.leave(w, dt) w.frame(PEN_FD, { {K, C.BTN_TOOL_PEN, 0} }, dt) end
local function pslot(w, evs, s)
  if w.panel_last_slot ~= s then evs[#evs + 1] = { A, C.ABS_MT_SLOT, s }; w.panel_last_slot = s end
end
function panel.down(w, s, tid, x, y, tool, dt)
  local evs = {}
  pslot(w, evs, s)
  evs[#evs + 1] = { A, C.ABS_MT_TRACKING_ID, tid }
  if w.panel_tool[s] ~= (tool or 0) then evs[#evs + 1] = { A, C.ABS_MT_TOOL_TYPE, tool or 0 }; w.panel_tool[s] = tool or 0 end
  evs[#evs + 1] = { A, C.ABS_MT_POSITION_X, x }
  evs[#evs + 1] = { A, C.ABS_MT_POSITION_Y, y }
  w.frame(PANEL_FD, evs, dt)
end
function panel.move(w, list, dt)
  local evs = {}
  for _i, p in ipairs(list) do
    pslot(w, evs, p[1])
    if p[4] and w.panel_tool[p[1]] ~= p[4] then evs[#evs + 1] = { A, C.ABS_MT_TOOL_TYPE, p[4] }; w.panel_tool[p[1]] = p[4] end
    evs[#evs + 1] = { A, C.ABS_MT_POSITION_X, p[2] }
    evs[#evs + 1] = { A, C.ABS_MT_POSITION_Y, p[3] }
  end
  w.frame(PANEL_FD, evs, dt)
end
function panel.up(w, s, dt)
  local evs = {}
  pslot(w, evs, s)
  evs[#evs + 1] = { A, C.ABS_MT_TRACKING_ID, -1 }
  w.frame(PANEL_FD, evs, dt)
end
local function strokeB(w)
  pen.enter(w, BX0 - 5, BY0 - 5, 300)
  for i = 1, 3 do pen.hover(w, BX0 - 5 + i, BY0 - 5 + i, 7) end
  pen.touch(w, BX0, BY0, 7)
  for i = 1, 12 do pen.move(w, BX0 + i * 10, BY0 - i * 6, 7) end
  pen.lift(w, 7)
  pen.leave(w, 40)
end

-- What came out: strokes joining A and B, strokes touching the palm, and jumps
-- inside a stroke.
local function analyse(w)
  local r = { strokes = #w.strokes, connects = 0, palm = 0, jumps = 0 }
  for _i, s in ipairs(w.strokes) do
    local seen = {}
    for k = 1, #s - 1, 2 do
      seen[region(s[k], s[k + 1])] = true
      if k > 1 then
        local d = math.sqrt((s[k] - s[k - 2]) ^ 2 + (s[k + 1] - s[k - 1]) ^ 2)
        if d > 300 then r.jumps = r.jumps + 1 end
      end
    end
    if seen.A and seen.B then r.connects = r.connects + 1 end
    if seen.P then r.palm = r.palm + 1 end
  end
  return r
end

local CASES = {
  { "S2", "palm (two finger contacts) rests while writing; then a far stroke", function(w)
      pen.enter(w, AX0 - 5, AY0 - 5, 50)
      pen.touch(w, AX0, AY0, 7)
      pen.move(w, AX0 + 10, AY0 + 5, 7)
      panel.down(w, 0, 101, 900, 1100, 0, 3)
      panel.down(w, 1, 102, 1000, 1200, 0, 3)
      for i = 2, 20 do
        pen.move(w, AX0 + i * 10, AY0 + i * 5, 4)
        if i % 2 == 0 then panel.move(w, { { 0, 900 + i, 1100 }, { 1, 1000 + i, 1200 } }, 3) end
      end
      pen.lift(w, 7)
      pen.hover(w, AX0 + 210, AY0 + 90, 7)
      panel.up(w, 0, 20); panel.up(w, 1, 5)
      pen.leave(w, 30)
      strokeB(w)
    end, 2 },
  { "S2b", "as S2, the panel flags the palm MT_TOOL_PALM", function(w)
      pen.enter(w, AX0 - 5, AY0 - 5, 50)
      pen.touch(w, AX0, AY0, 7)
      pen.move(w, AX0 + 10, AY0 + 5, 7)
      panel.down(w, 0, 101, 900, 1100, 0, 3)
      panel.down(w, 1, 102, 1000, 1200, 0, 3)
      panel.move(w, { { 0, 901, 1100, 2 }, { 1, 1001, 1200, 2 } }, 3)
      for i = 2, 20 do
        pen.move(w, AX0 + i * 10, AY0 + i * 5, 4)
        if i % 2 == 0 then panel.move(w, { { 0, 900 + i, 1100 }, { 1, 1000 + i, 1200 } }, 3) end
      end
      pen.lift(w, 7)
      pen.hover(w, AX0 + 210, AY0 + 90, 7)
      panel.up(w, 0, 20); panel.up(w, 1, 5)
      pen.leave(w, 30)
      strokeB(w)
    end, 2 },
  { "S6", "four short strokes with a resting palm jittering, then a far stroke", function(w)
      pen.enter(w, AX0 - 5, AY0 - 5, 50)
      panel.down(w, 0, 401, 950, 1200, 0, 3)
      local jitter = 0
      for s = 0, 3 do
        local x0 = AX0 + s * 90
        pen.hover(w, x0 - 2, AY0 - 2, 7)
        pen.touch(w, x0, AY0, 7)
        for i = 1, 10 do
          pen.move(w, x0 + i * 6, AY0 + (i % 4) * 10, 6)
          if i % 3 == 0 then jitter = jitter + 1; panel.move(w, { { 0, 950 + jitter, 1200 + jitter } }, 2) end
        end
        pen.lift(w, 6)
        pen.hover(w, x0 + 60, AY0 - 10, 6)
      end
      panel.up(w, 0, 30)
      pen.leave(w, 30)
      strokeB(w)
    end, 5 },
  { "S7b", "the hand's edge, reported as a pen, rests on the panel while writing", function(w)
      panel.down(w, 0, 711, 1000, 1200, 1, 50)
      pen.enter(w, AX0 - 5, AY0 - 5, 10)
      pen.touch(w, AX0, AY0, 7)
      for i = 1, 20 do
        pen.move(w, AX0 + i * 10, AY0 + i * 5, 4)
        if i % 2 == 0 then panel.move(w, { { 0, 1000 + i * 2, 1200 + i } }, 3) end
      end
      pen.lift(w, 7)
      pen.hover(w, AX0 + 210, AY0 + 90, 7)
      panel.up(w, 0, 20)
      pen.leave(w, 30)
      strokeB(w)
    end, 2 },
}

local steps = { { wait = 2.5, function(api) end } }
-- a palm (MT_TOOL_PALM) resting while a text dialog is up: Glossator keeps it
-- from KOReader, where it would be a tap that puts the keyboard away
table.insert(steps, { wait = 0.3, function(api)
  local ink = api.plugin("inkai")
  local InputDialog = require("ui/widget/inputdialog")
  local d = InputDialog:new{ title = "Follow-up question", buttons = {{ { text = "OK", callback = function() end } }} }
  api.UIManager:show(d)
  local w = newWorld(ink, true)
  panel.down(w, 0, 901, 900, 1200, 2, 20)
  for i = 1, 5 do panel.move(w, { { 0, 900 + i * 3, 1200 + i } }, 8) end
  panel.up(w, 0, 20)
  local passed = w.palm_passed
  w.restore()
  api.UIManager:close(d)
  out(string.format("%s palm over a dialog is kept from KOReader (%d palm frames passed on)", passed == 0 and "PASS" or "FAIL", passed))
end })
local summary = {}
for _i, c in ipairs(CASES) do
  for _j, bridge in ipairs({ true, false }) do
    table.insert(steps, { wait = 0.3, function(api)
      local ink = api.plugin("inkai")
      ink:onGlossatorReset()
      local n0 = #ink.data.groups
      local w = newWorld(ink, bridge)
      local ok, err = pcall(c[3], w)
      local r = analyse(w)
      w.restore()
      local good = ok and r.connects == 0 and r.palm == 0 and r.jumps == 0 and r.strokes == c[4]
      out(string.format("%s %s [%s, bridge %s]: %d strokes (want %d), %d joining A-B, %d at the palm, %d jumps%s",
        good and "PASS" or (bridge and "FAIL" or "BUG "), c[1], c[2], w.bridged and "on" or "off",
        r.strokes, c[4], r.connects, r.palm, r.jumps, ok and "" or (" ERROR " .. tostring(err))))
      ink:onGlossatorReset()
    end })
  end
end
table.insert(steps, { wait = 0.5, function(api)
  local f = io.open(os.getenv("INKAI_SHOTS") .. "/scribepalm.txt", "w"); f:write(table.concat(log, "\n") .. "\n"); f:close()
end })
return steps
