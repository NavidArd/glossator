local DataStorage = require("datastorage")
local mockp = DataStorage:getDataDir() .. "/inkai_mock.txt"
local MOCK2 = [[<transcription>and for SU(2)?</transcription>
<note>Same idea: $U=e^{-i\theta\,\hat n\cdot\vec J}$, with the three $J_i=\tfrac12\sigma_i$ as generators.</note>]]
local MOCK1 = [[<transcription>?</transcription><note>The generator is the velocity of the group at the identity: $X=\frac{dg}{d\epsilon}\big|_{0}$.</note>]]
local log = {}
local function check(name, cond) table.insert(log, (cond and "PASS " or "FAIL ") .. name) end
return {
  { wait = 2, function(api) api.event("SetZoomMode", "pagewidth") end },
  -- 1. no key, no mock: asking says where the key goes
  { wait = 1, function(api)
      os.remove(mockp)
      api.pen(api.circle(1150, 460, 260, 50))
  end },
  { wait = 1, function(api)
      local c = api.plugin("inkai").chip
      check("chip shows after writing", c ~= nil)
      api.tap(c.rect.x + 20, c.rect.y + c.rect.h / 2)
  end },
  { wait = 1, function(api)
      local top = api.UIManager:getTopmostVisibleWidget()
      check("missing key message", top and top.text and top.text:find("glossator_key.txt") ~= nil)
      api.shot("f1-nokey")
      api.UIManager:close(top)
  end },
  -- 2. ask with a mock answer
  { wait = 0.5, function(api)
      local f = io.open(mockp, "w"); f:write(MOCK1); f:close()
      local inkai = api.plugin("inkai")
      inkai:showChip(inkai.data.groups[1])
      local c = inkai.chip
      api.tap(c.rect.x + 20, c.rect.y + c.rect.h / 2)
  end },
  { wait = 3, function(api)
      local inkai = api.plugin("inkai")
      check("answer stored", inkai.data.groups[1].note ~= nil)
      check("answer placed", #inkai.cache.hits == 1)
      -- 3. follow up, in the opened note
      local h = inkai.cache.hits[1].rect
      api.tap(h.x + h.w / 2, h.y + h.h / 2)
  end },
  { wait = 1, function(api)
      local top = api.UIManager:getTopmostVisibleWidget()
      check("note opens", top and top.group ~= nil)
      local f = io.open(mockp, "w"); f:write(MOCK2); f:close()
      top:ask({ typed = "and for SU(2)?" })
  end },
  { wait = 3, function(api)
      local inkai = api.plugin("inkai")
      local g = inkai.data.groups[1]
      check("follow-up in the conversation", g.replies and #g.replies == 1 and g.replies[1].note ~= nil)
      local top = api.UIManager:getTopmostVisibleWidget()
      api.shot("f2-followup")
      top:close()
  end },
  { wait = 0.8, function(api)
      check("one note on the page, with its follow-up", #api.plugin("inkai").cache.hits == 1)
  end },
  -- 4. a plain annotation, then the eraser end rubs it out
  { wait = 0.5, function(api) api.pen({ 300,2150, 600,2160 }) end },
  { wait = 0.5, function(api) api.tap(1200, 1500) end },
  { wait = 0.5, function(api)
      local n = #api.plugin("inkai").data.groups
      check("plain ink kept", n == 2)
      api.pen({ 280,2140, 450,2165, 620,2150 }, 2)
  end },
  { wait = 1, function(api)
      check("eraser removed it", #api.plugin("inkai").data.groups == 1)
      -- 5. a second note, then delete it
      table.insert(api.plugin("inkai").data.groups, { id = "x", created = os.time() + 1, a = api.plugin("inkai").data.groups[1].a, box = api.plugin("inkai").data.groups[1].box, strokes = {}, note = "tmp" })
      api.plugin("inkai"):deleteGroup(api.plugin("inkai").data.groups[2], true)
      check("deleted", #api.plugin("inkai").data.groups == 1)
      api.ui():saveSettings()
  end },
  { wait = 1, function(api)
      local f = io.open(os.getenv("INKAI_SHOTS") .. "/flows.txt", "w"); f:write(table.concat(log, "\n") .. "\n"); f:close()
  end },
}
