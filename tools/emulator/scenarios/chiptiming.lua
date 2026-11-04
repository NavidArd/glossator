-- The Ask AI chip waits while you write: not while the pen hovers over the
-- page, and it hides when you start writing again. Run with CHIP_DELAY=1.6
-- (the plugin's own delay).
local Device = require("device")
local time = require("ui/time")
local log = {}
local function check(name, cond) table.insert(log, (cond and "PASS " or "FAIL ") .. name) end
local function hover(x, y)
  local inp = Device.input
  inp.stylus_callback(inp, { slot = 0, id = -1, x = x, y = y, tool = 1, timev = time.now() })
end
local function i(api) return api.plugin("inkai") end
return {
  { wait = 2.5, function(api) api.pen({ 1500, 900, 1560, 960, 1620, 900 }) end },
  { wait = 0.8, function(api)
      check("no chip right after the pen lifts", i(api).chip == nil)
      hover(1650, 950)
  end },
  { wait = 0.6, function(api) hover(1660, 955) end },
  { wait = 0.6, function(api) hover(1670, 960) end },
  { wait = 0.3, function(api)
      check("no chip while the pen hovers", i(api).chip == nil)
  end },
  { wait = 1.6, function(api)
      check("chip once the pen has rested", i(api).chip ~= nil)
      local c = i(api).chip
      local ink = i(api):screenOf(i(api).fresh).box
      check("chip not to the right of the ink on its line", not (c.rect.x >= ink.x + ink.w and c.rect.y < ink.y + ink.h and c.rect.y + c.rect.h > ink.y))
      api.shot("c1-chip-above")
      -- writing again: the chip makes way
      api.pen({ 1500, 1000, 1560, 1010 })
  end },
  { wait = 0.3, function(api)
      check("chip hides when you write again", i(api).chip == nil)
      local f = io.open(os.getenv("INKAI_SHOTS") .. "/chip.txt", "w"); f:write(table.concat(log, "\n") .. "\n"); f:close()
  end },
}
