local DataStorage = require("datastorage")
local mockp = DataStorage:getDataDir() .. "/inkai_mock.txt"
local MOCK = [[<transcription>selected: For rotations in the plane</transcription>
<note>$R(\theta)$ is a one-parameter group: $R(\alpha)R(\beta)=R(\alpha+\beta)$, so one generator $X$ gives them all, $R(\theta)=e^{\theta X}$.</note>]]
local log = {}
local function check(name, cond) table.insert(log, (cond and "PASS " or "FAIL ") .. name) end
local function inkai(api) return api.plugin("inkai") end
local function tapItem(api, id)
  local tb = inkai(api).toolbar
  for _, it in ipairs(tb.items or {}) do
    if it.id == id then api.tap(it.rect.x + it.rect.w / 2, it.rect.y + it.rect.h / 2) return true end
  end
  for _, it in ipairs(tb.opt_items or {}) do
    if it.arg == id then api.tap(it.rect.x + it.rect.w / 2, it.rect.y + it.rect.h / 2) return true end
  end
  return false
end
local function dump(api, tag)
  local i = inkai(api)
  for k, g in ipairs(i.data.groups) do
    table.insert(log, string.format("  [%s] g%d id=%s page=%s strokes=%d note=%s sel=%s status=%s", tag, k, tostring(g.id), tostring(g.a and g.a.page), #(g.strokes or {}), tostring(g.note ~= nil), tostring(g.selected_text ~= nil), tostring(g.status)))
  end
  for _, h in ipairs(i.cache.hits or {}) do
    table.insert(log, string.format("  [%s] hit %d,%d %dx%d", tag, h.rect.x, h.rect.y, h.rect.w, h.rect.h))
  end
end
local function nstrokes(api)
  local n = 0
  for _, g in ipairs(inkai(api).data.groups) do n = n + #(g.strokes or {}) end
  return n
end
return {
  { wait = 2.5, function(api)
      local f = io.open(mockp, "w"); f:write(MOCK); f:close()
      check("toolbar tab shown", inkai(api).toolbar:state() == "tab")
      check("tap opens toolbar", tapItem(api, "openbar"))
  end },
  { wait = 1, function(api)
      check("toolbar open", inkai(api).toolbar:state() == "open")
      tapItem(api, "pen") -- pen already selected: options
  end },
  { wait = 0.7, function(api)
      check("pen options shown", inkai(api).toolbar.options == "pen")
      api.shot("u1-toolbar-pen-options")
      tapItem(api, 3)
  end },
  { wait = 0.7, function(api)
      check("bold pen chosen", inkai(api):penWidth() == 3)
      api.pen(api.circle(900, 1020, 330, 75))
  end },
  { wait = 1.2, function(api)
      local g = inkai(api).data.groups[1]
      check("bold stroke stored", g and g.strokes[1].w == 3)
      inkai(api):hideChip(true)
      tapItem(api, "marker")
  end },
  { wait = 0.7, function(api)
      check("marker tool", inkai(api):tool() == "marker")
      local before = #(api.ui().annotation.annotations or {})
      api.pen({ 430, 1411, 600, 1412, 800, 1410, 960, 1413 })
      _G.__ann_before = before
  end },
  { wait = 1.2, function(api)
      local n = #(api.ui().annotation.annotations or {})
      check("marker made a KOReader highlight", n == _G.__ann_before + 1)
      local c = inkai(api).chip
      check("Ask AI offered for the highlight", c and c.group.transient == true)
      api.shot("u2-marker-highlight")
      dump(api, "u2")
      inkai(api):hideChip(true)
      tapItem(api, "pen")
  end },
  { wait = 0.5, function(api)
      api.pen({ 500, 2290, 700, 2292, 900, 2290, 1100, 2291, 1300, 2290 })
  end },
  { wait = 0.8, function(api)
      inkai(api):hideChip(true)
      inkai(api).fresh = nil
      tapItem(api, "eraser")
  end },
  { wait = 0.5, function(api) tapItem(api, "eraser") end },
  { wait = 0.5, function(api)
      check("eraser options", inkai(api).toolbar.options == "eraser")
      tapItem(api, "precise")
  end },
  { wait = 0.5, function(api)
      check("precise eraser", inkai(api):eraserMode() == "precise")
      _G.__n0 = nstrokes(api)
      api.pen({ 900, 2230, 900, 2260, 900, 2290, 900, 2320, 900, 2350 })
  end },
  { wait = 1, function(api)
      check("precise erase split the line in two", nstrokes(api) == _G.__n0 + 1)
      api.shot("u3-precise-erase")
      tapItem(api, "pen")
  end },
  { wait = 0.5, function(api)
      api.pen({ 1560, 1760, 1640, 1840 })
      api.pen({ 1640, 1760, 1560, 1840 })
  end },
  { wait = 0.8, function(api)
      inkai(api):hideChip(true)
      inkai(api).fresh = nil
      tapItem(api, "lasso")
  end },
  { wait = 0.5, function(api)
      _G.__n1 = nstrokes(api)
      api.pen(api.circle(1600, 1800, 110, 110, 0))
  end },
  { wait = 0.8, function(api)
      local sel = inkai(api).sel
      check("lasso selected two strokes", sel and #sel.items == 2)
      api.shot("u4-lasso")
      dump(api, "u4")
      -- drag the selection down with the pen
      api.pen({ 1600, 1800, 1600, 1850, 1600, 1900, 1600, 1950 })
  end },
  { wait = 1, function(api)
      local inkai_ = inkai(api)
      local moved = false
      for _, g in ipairs(inkai_.data.groups) do
        local sc = inkai_:screenOf(g)
        if sc and sc.box and sc.box.y > 1880 and sc.box.y < 1960 and sc.box.x > 1500 then moved = true end
      end
      check("lasso moved the strokes", moved)
      local c = inkai_.chip
      check("selection chip has Delete", c and c.segments[2] and c.segments[2].label == "Delete")
      local seg = c.segments[2].rect
      api.tap(seg.x + seg.w / 2, seg.y + seg.h / 2)
  end },
  { wait = 0.8, function(api)
      check("lasso delete", nstrokes(api) == _G.__n1 - 2)
      tapItem(api, "undo")
  end },
  { wait = 0.8, function(api)
      check("undo brings them back", nstrokes(api) == _G.__n1)
      tapItem(api, "redo")
  end },
  { wait = 0.8, function(api)
      check("redo deletes again", nstrokes(api) == _G.__n1 - 2)
      -- Ask AI on selected text (as the highlight popup's button does)
      local ui = api.ui()
      local p0 = ui.view:screenToPageTransform({ x = 430, y = 1129 })
      local p1 = ui.view:screenToPageTransform({ x = 1000, y = 1129 })
      local sel = ui.document:getTextFromPositions(p0, p1)
      local hl = { selected_text = sel, highlightFromHoldPos = function() end, onClose = function() end }
      inkai(api):askSelection(hl)
  end },
  { wait = 3.5, function(api)
      local found
      for _, g in ipairs(inkai(api).data.groups) do if g.selected_text and g.note then found = g end end
      check("selection asked and answered", found ~= nil)
      check("selection note placed", #inkai(api).cache.hits >= 1)
      api.shot("u5-selection-note")
      dump(api, "u5")
      inkai(api):exportMarkdown()
  end },
  { wait = 1, function(api)
      local top = api.UIManager:getTopmostVisibleWidget()
      local path = top and top.text and top.text:match("\n(.+%.md)")
      local f = path and io.open(path)
      local body = f and f:read("*a") or ""
      if f then f:close() end
      check("export written", body:find("one%-parameter group") ~= nil)
      if top then api.UIManager:close(top) end
      -- the top bar's pen button toggles the toolbar
      api.tap(900, 100)
  end },
  { wait = 1.2, function(api)
      api.shot("u6-topbar")
      local bars = api.plugin("kindleui").bars
      local pen
      for _, h in ipairs(bars and bars.hits or {}) do end
      check("top bar open", bars ~= nil)
      api.event("GlossatorToolbar")
  end },
  { wait = 0.8, function(api)
      check("toolbar folded by event", inkai(api).toolbar:state() == "tab")
      local f = io.open(os.getenv("INKAI_SHOTS") .. "/tools.txt", "w"); f:write(table.concat(log, "\n") .. "\n"); f:close()
  end },
}
