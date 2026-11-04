local DataStorage = require("datastorage")
local Device = require("device")
local time = require("ui/time")
local MOCK = [[<transcription>why?</transcription><note>Each tiny step multiplies by $\left(I+\frac{\theta}{N}X\right)$; compounding gives $e^{\theta X}$.</note>]]
local log = {}
local function check(name, cond) table.insert(log, (cond and "PASS " or "FAIL ") .. name) end
local function page(api) return api.ui():getCurrentPage() end
local function frame(x, y, id)
  local inp = Device.input
  inp.stylus_callback(inp, { slot = 0, id = id, x = x, y = y, tool = 1, timev = time.now() })
end
local function top(api) return api.UIManager:getTopmostVisibleWidget() end
return {
  { wait = 2.5, function(api)
      local f = io.open(DataStorage:getDataDir() .. "/inkai_mock.txt", "w"); f:write(MOCK); f:close()
      _G.__p = page(api)
      api.pen({ 1500, 1600, 1501, 1601 }) -- a quick pen tap on the right
  end },
  { wait = 1.2, function(api)
      check("pen tap turns the page", page(api) == _G.__p + 1)
      api.pen({ 100, 1600, 101, 1600 }) -- and on the left
  end },
  { wait = 1.2, function(api)
      check("pen tap on the left goes back", page(api) == _G.__p)
      check("no ink from taps", #api.plugin("inkai").data.groups == 0)
      -- write, then a dot right after: the dot is ink
      api.pen({ 1550, 1700, 1600, 1720, 1650, 1700 })
      api.pen({ 1680, 1705, 1681, 1706 })
  end },
  { wait = 1.2, function(api)
      check("a dot after writing stays ink", page(api) == _G.__p)
      local n = 0
      for _, g in ipairs(api.plugin("inkai").data.groups) do n = n + #g.strokes end
      check("both strokes kept", n == 2)
      api.plugin("inkai"):hideChip(true)
      api.plugin("inkai").last_ink = nil
      -- a pen held still on a word: selects it
      frame(600, 1129, 0)
  end },
  { wait = 0.9, function(api) frame(600, 1129, 0) end },
  { wait = 0.3, function(api) frame(600, 1129, -1) end },
  { wait = 1.2, function(api)
      local t = top(api)
      local hl = api.ui().highlight
      check("pen long-press selected text", hl.selected_text ~= nil or (t and t ~= api.ui()))
      api.shot("x1-pen-hold")
      if t and t ~= api.ui() then api.UIManager:close(t) end
      pcall(hl.clear, hl)
  end },
  -- ask, answer, then pages still turn (finger and pen)
  { wait = 0.8, function(api)
      api.pen(api.circle(930, 1022, 350, 74))
  end },
  { wait = 1.2, function(api)
      local c = api.plugin("inkai").chip
      api.tap(c.rect.x + 20, c.rect.y + c.rect.h / 2)
  end },
  { wait = 3.5, function(api)
      local g
      for _, o in ipairs(api.plugin("inkai").data.groups) do if o.note then g = o end end
      check("answered", g ~= nil)
      _G.__g = g
      _G.__p = page(api)
      api.pen({ 1500, 2000, 1501, 2001 })
  end },
  { wait = 1.2, function(api)
      check("pen tap turns the page after an answer", page(api) == _G.__p + 1)
      api.tap(100, 1600)
  end },
  { wait = 1.2, function(api)
      check("finger tap back after an answer", page(api) == _G.__p)
      api.shot("x2-aa-ink")
      -- open the note: the conversation card with its pad
      local h = api.plugin("inkai").cache.hits[1]
      api.tap(h.rect.x + h.rect.w / 2, h.rect.y + h.rect.h / 2)
  end },
  { wait = 1, function(api)
      local v = top(api)
      check("note card opens", v and v.pad ~= nil)
      -- write a follow-up on the pad with the pen (through the stylus callback)
      _G.__ng = #api.plugin("inkai").data.groups
      local d = v.pad.dimen
      local x0, y0 = d.x + 40, d.y + math.floor(d.h / 2)
      api.pen({ x0, y0, x0 + 30, y0 - 25, x0 + 60, y0, x0 + 90, y0 - 25, x0 + 120, y0 })
      api.pen({ x0 + 160, y0 - 30, x0 + 160, y0 + 10 })
  end },
  { wait = 0.8, function(api)
      local v = top(api)
      check("pen writes on the card's pad", v and #v.pad.strokes == 2)
      check("no ink on the page from the pad", #api.plugin("inkai").data.groups == _G.__ng)
      api.shot("x3-card-pad")
      v:askWritten()
  end },
  { wait = 0.4, function(api)
      local v = top(api)
      check("card shows Thinking", v and v.pending == true)
      api.shot("x4-card-thinking")
  end },
  { wait = 3, function(api)
      local v = top(api)
      check("written follow-up answered in the card", _G.__g.replies and #_G.__g.replies == 1 and v and not v.pending)
      api.shot("x5-card-reply")
      -- and a typed one
      v:ask({ typed = "and for SU(2)?" })
  end },
  { wait = 3.5, function(api)
      local v = top(api)
      check("typed follow-up answered in the card", #_G.__g.replies == 2 and _G.__g.replies[2].question == "and for SU(2)?")
      api.shot("x6-card-two-replies")
      v:close()
  end },
  { wait = 1, function(api)
      check("card closed, page on top", top(api) == api.ui())
      check("note says 2 follow-ups", api.plugin("inkai").cache.hits[1] ~= nil)
      api.shot("x7-note-with-followups")
      _G.__p = page(api)
      api.tap(1500, 1600)
  end },
  { wait = 1.2, function(api)
      check("not locked: page turns", page(api) == _G.__p + 1)
      api.plugin("inkai"):onGlossatorReset()
  end },
  { wait = 1, function(api)
      check("reset leaves the pen attached", require("device").input.stylus_callback == api.plugin("inkai").stylus_cb)
      local f = io.open(os.getenv("INKAI_SHOTS") .. "/fixes.txt", "w"); f:write(table.concat(log, "\n") .. "\n"); f:close()
  end },
}
