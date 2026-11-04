local DataStorage = require("datastorage")
local MOCK = [[<transcription>Circled "∂_μ J^μ = 0" and wrote "?"</transcription>
<note>It's a continuity equation: $\partial_t J^0 = -\nabla\cdot\vec J$. Integrate over all space and the flux term vanishes, so $\frac{dQ}{dt}=0$.</note>
<more>Split $\partial_\mu J^\mu = \partial_t J^0 + \nabla\cdot\vec J$. Then
$$\frac{d}{dt}\int d^3x\, J^0 = -\int d^3x\,\nabla\cdot\vec J = -\oint \vec J\cdot d\vec S = 0$$
if the current dies off at infinity. That is Noether's charge for a field.</more>]]
return {
  { wait = 2, function(api) api.event("SetZoomMode", "pagewidth") end },
  { wait = 1, function(api) api.event("GotoViewRel", 1) end },
  { wait = 1.5, function(api)
      api.pen(api.circle(1470, 940, 200, 62))
      api.pen({ 1700,850, 1712,832, 1735,826, 1755,838, 1755,862, 1735,880, 1728,905 })
      api.pen({ 1727,935, 1729,938 })
  end },
  { wait = 1.5, function(api) api.shot("s1-ink") end },
  { wait = 0.2, function(api)
      local f = io.open(DataStorage:getDataDir() .. "/inkai_mock.txt", "w"); f:write(MOCK); f:close()
      local c = api.plugin("inkai").chip
      api.tap(c.rect.x + 30, c.rect.y + c.rect.h / 2)
  end },
  { wait = 3, function(api) api.shot("s2-answer") end },
  { wait = 0.5, function(api) api.event("GotoViewRel", 0.3) end },
  { wait = 1.5, function(api) api.shot("s3-scrolled") end },
}
