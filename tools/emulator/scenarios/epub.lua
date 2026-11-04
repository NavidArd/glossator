local DataStorage = require("datastorage")
local MOCK = [[<transcription>Underlined "angular momentum"</transcription>
<note>Rotations about an axis leave $L$ unchanged, so the conserved charge is $\vec L=\vec r\times\vec p$.</note>]]
return {
  { wait = 2, function(api) api.event("GotoViewRel", 1) end },
  { wait = 1.5, function(api) api.shot("e0") end },
  { wait = 0.5, function(api)
      local ui = api.ui()
      -- underline the word "momentum" found on the screen
      local sel = ui.document:getTextFromPositions({ x = 0, y = 0 }, { x = 1860, y = 2480 }, true)
      local w = ui.document:getWordFromPosition({ x = 10, y = 10 }, true)
      -- find "angular" by scanning words along the lines
      local b
      for y = 100, 2300, 20 do
        for x = 40, 1800, 60 do
          local wd = ui.document:getWordFromPosition({ x = x, y = y }, true)
          if wd and wd.word == "angular" then b = wd.sbox break end
        end
        if b then break end
      end
      b = { x = b.x, y = b.y, w = b.w * 2.3, h = b.h }
      api.pen({ b.x, b.y + b.h + 6, b.x + b.w * 0.5, b.y + b.h + 9, b.x + b.w, b.y + b.h + 5 })
  end },
  { wait = 1.2, function(api)
      local f = io.open(DataStorage:getDataDir() .. "/inkai_mock.txt", "w"); f:write(MOCK); f:close()
      local c = api.plugin("inkai").chip
      api.tap(c.rect.x + 30, c.rect.y + c.rect.h / 2)
  end },
  { wait = 3, function(api) api.shot("e1-answer") end },
  { wait = 0.3, function(api) api.event("SetFontSize", 30) end },
  { wait = 2, function(api) api.shot("e2-bigger-font") end },
}
