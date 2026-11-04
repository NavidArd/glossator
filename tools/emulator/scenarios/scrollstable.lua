local DataStorage = require("datastorage")
local MOCK = [[<transcription>?</transcription><note>Continuity: $\partial_t J^0=-\nabla\cdot\vec J$.</note>]]
local log = {}
local function check(name, cond) table.insert(log, (cond and "PASS " or "FAIL ") .. name) end
local function noteRel(api)
  local i = api.plugin("inkai")
  local g = i.data.groups[1]
  local p = i:placeOf(g)
  local sx, sy = i.book:toScreen(g.a.page, 0, 0)
  if not p then return nil end
  return { dx = p.rect.x - sx, dy = p.rect.y - sy, y = p.rect.y }
end
return {
  { wait = 2, function(api) api.event("SetZoomMode", "pagewidth") end },
  { wait = 1, function(api) api.event("GotoViewRel", 1) end },
  { wait = 1.5, function(api)
      local f = io.open(DataStorage:getDataDir() .. "/inkai_mock.txt", "w"); f:write(MOCK); f:close()
      check("in scroll mode", api.ui().view.page_scroll == true)
      api.pen(api.circle(1470, 940, 200, 62))
  end },
  { wait = 1, function(api) local c = api.plugin("inkai").chip; api.tap(c.rect.x + 20, c.rect.y + c.rect.h / 2) end },
  { wait = 3, function(api)
      _G.__r0 = noteRel(api)
      check("note placed", _G.__r0 ~= nil)
      api.ui().paging:onScrollPanRel(-150)
  end },
  { wait = 1.5, function(api)
      local r1 = noteRel(api)
      check("note moved with the page", r1 and r1.y ~= _G.__r0.y)
      check("note kept its place on the page", r1 and math.abs(r1.dx - _G.__r0.dx) < 1 and math.abs(r1.dy - _G.__r0.dy) < 1)
      local n = 0
      for _ in pairs(api.plugin("inkai").place_cache) do n = n + 1 end
      check("placement cached once", n == 1)
      api.shot("v1-scrolled")
      local f = io.open(os.getenv("INKAI_SHOTS") .. "/scroll.txt", "w"); f:write(table.concat(log, "\n") .. "\n"); f:close()
  end },
}
