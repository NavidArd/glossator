-- The hand on the glass while writing doesn't turn the page; the toolbar and
-- the chip still answer a finger; the follow-up Keyboard button opens the
-- on-screen keyboard; the key file picks the provider. Run with
-- EXTRA_SETTINGS='["virtual_keyboard_enabled"] = true,' (the Linux build has a
-- real keyboard, so the on-screen one is off by default).
local DataStorage = require("datastorage")
local dir = DataStorage:getDataDir()
local MOCK = [[<transcription>?</transcription><note>The generator is the velocity of the group at the identity.</note>]]
local log = {}
local function check(name, cond) table.insert(log, (cond and "PASS " or "FAIL ") .. name) end
local function page(api) return api.ui():getCurrentPage() end
local function top(api) return api.UIManager:getTopmostVisibleWidget() end
local function ink(api) return api.plugin("inkai") end
local function onStack(api, name)
  for _i, w in ipairs(api.UIManager._window_stack) do
    if w.widget.name == name then return w.widget end
  end
end
local function tapItem(api, id)
  for _i, it in ipairs(ink(api).toolbar.items or {}) do
    if it.id == id then api.tap(it.rect.x + it.rect.w / 2, it.rect.y + it.rect.h / 2) return true end
  end
end
local function writeKeys(text)
  local f = io.open(dir .. "/glossator_key.txt", "w"); f:write(text); f:close()
end
return {
  { wait = 2, function(api)
      os.remove(dir .. "/glossator_key.txt")
      os.remove(dir .. "/inkai_key.txt")
      os.remove(dir .. "/inkai_mock.txt")
      os.remove(dir .. "/glossator_mock.txt")
      _G.__p = page(api)
      api.pen({ 1450, 1700, 1500, 1720, 1550, 1700, 1600, 1720 })
      -- the wrist lands on the right of the page as the pen lifts
      api.tap(1500, 2100)
  end },
  { wait = 0.5, function(api)
      check("palm tap while writing doesn't turn the page", page(api) == _G.__p)
      api.tap(1500, 2100)
  end },
  { wait = 0.4, function(api)
      check("palm tap just after writing doesn't either", page(api) == _G.__p)
  end },
  { wait = 1.5, function(api)
      ink(api):hideChip(true) -- (with the chip up, a tap only puts it away)
      api.tap(1500, 2100)
  end },
  { wait = 1, function(api)
      check("a finger tap once you've stopped writing turns the page", page(api) == _G.__p + 1)
      api.tap(100, 1600)
  end },
  { wait = 1, function(api)
      _G.__p = page(api)
      api.pen({ 1450, 1300, 1500, 1320, 1550, 1300 })
      -- a pen tap far from the ink, right after writing, still turns the page
      api.pen({ 1500, 1950, 1501, 1951 })
  end },
  { wait = 1, function(api)
      check("pen tap right after writing still turns the page", page(api) == _G.__p + 1)
      ink(api):hideChip(true)
      api.tap(100, 1600)
  end },
  { wait = 1, function(api)
      -- the toolbar answers a finger right after writing
      ink(api).toolbar:setState("open")
      ink(api):repaint()
  end },
  { wait = 0.5, function(api)
      api.pen({ 1300, 1500, 1350, 1520, 1400, 1500 })
      tapItem(api, "eraser")
  end },
  { wait = 0.5, function(api)
      check("toolbar tap right after writing works", ink(api):tool() == "eraser")
      tapItem(api, "pen")
  end },
  -- keys: an OpenRouter key alone, with a Claude model, goes through OpenRouter
  { wait = 0.5, function(api)
      G_reader_settings:saveSetting("inkai_model", "claude-opus-5-5")
      writeKeys("sk-or-v1-test\n")
      local c = ink(api):credentials()
      check("OpenRouter key alone: Claude via OpenRouter", c and c.provider == "openrouter" and c.model == "anthropic/claude-opus-5.5")
      writeKeys("sk-ant-test\nsk-or-v1-test\n")
      c = ink(api):credentials()
      check("both keys: Claude direct", c and c.provider == "anthropic" and c.key == "sk-ant-test" and c.model == "claude-opus-5-5")
      G_reader_settings:saveSetting("inkai_model", "openrouter:google/gemini-3.8-flash")
      c = ink(api):credentials()
      check("Gemini through OpenRouter", c and c.provider == "openrouter" and c.key == "sk-or-v1-test" and c.model == "google/gemini-3.8-flash")
      writeKeys("sk-ant-test\n")
      c = ink(api):credentials()
      local t = top(api)
      check("Gemini without an OpenRouter key says so", c == nil and t and t.text and t.text:find("OpenRouter key") ~= nil)
      api.shot("k1-needs-openrouter")
      if t ~= api.ui() then api.UIManager:close(t) end
      os.remove(dir .. "/glossator_key.txt")
      G_reader_settings:saveSetting("inkai_model", "claude-opus-5-5")
  end },
  -- the follow-up keyboard
  { wait = 0.5, function(api)
      local f = io.open(dir .. "/inkai_mock.txt", "w"); f:write(MOCK); f:close()
      api.pen(api.circle(930, 1022, 350, 74))
  end },
  { wait = 1.6, function(api)
      local c = ink(api).chip
      api.tap(c.rect.x + 20, c.rect.y + c.rect.h / 2)
  end },
  { wait = 3, function(api)
      local h = ink(api).cache.hits[1]
      check("answered", h ~= nil)
      api.tap(h.rect.x + h.rect.w / 2, h.rect.y + h.rect.h / 2)
  end },
  { wait = 1, function(api)
      local v = top(api)
      check("card opens", v and v.pad ~= nil)
      local b = v.buttons:getButtonById("keyboard")
      api.tap(b.dimen.x + b.dimen.w / 2, b.dimen.y + b.dimen.h / 2)
  end },
  { wait = 1.5, function(api)
      local vk = onStack(api, "VirtualKeyboard")
      check("Keyboard opens the on-screen keyboard", vk ~= nil and vk.visible ~= false)
      check("question dialog above the page", top(api) ~= api.ui() and top(api).pad == nil)
      api.shot("k2-follow-up-keyboard")
      -- a stray touch outside the keyboard (the hand, the tail of the pen tap)
      api.tap(900, 150)
  end },
  { wait = 1, function(api)
      local vk = onStack(api, "VirtualKeyboard")
      check("a stray tap doesn't put the keyboard away", vk ~= nil and vk.visible ~= false)
      local d
      for _i, w in ipairs(api.UIManager._window_stack) do
        if w.widget.getInputText then d = w.widget end
      end
      if d then d:setInputText("and for SU(2)?") end
      for _i, row in ipairs(d and d.button_table and d.button_table.buttons or {}) do
        for _j, b in ipairs(row) do if b.text == "Ask" then b.callback() end end
      end
  end },
  { wait = 3.5, function(api)
      local v = top(api)
      local g
      for _i, o in ipairs(ink(api).data.groups) do if o.note then g = o end end
      check("typed follow-up answered in the card", v and v.pad and g and g.replies and #g.replies == 1 and g.replies[1].question == "and for SU(2)?")
      api.shot("k3-typed-answer")
      if v and v.close then v:close() end
      os.remove(dir .. "/inkai_mock.txt")
      local f = io.open(os.getenv("INKAI_SHOTS") .. "/palmkeys.txt", "w"); f:write(table.concat(log, "\n") .. "\n"); f:close()
  end },
}
