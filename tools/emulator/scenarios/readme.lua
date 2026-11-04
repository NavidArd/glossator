-- Screenshots for the README: the conversation in a note (with different
-- answers), typing a follow-up, the model menu. Run with
-- EXTRA_SETTINGS='["virtual_keyboard_enabled"] = true,'
local DataStorage = require("datastorage")
local mockp = DataStorage:getDataDir() .. "/inkai_mock.txt"
local function mock(s) local f = io.open(mockp, "w"); f:write(s); f:close() end
local M1 = [[<transcription>why?</transcription>
<note>Each tiny step multiplies by $\left(I+\frac{\theta}{N}X\right)$. Compounding $N\to\infty$ of them is how $e^{x}$ is defined, so $g(\theta)=e^{\theta X}$.</note>]]
local M2 = [[<transcription>so X is like a velocity?</transcription>
<note>Yes: $X=\frac{dg}{d\theta}\big|_{0}$ is the velocity of the curve $g(\theta)$ at the identity, the tangent vector of the group there.</note>]]
local M3 = [[<transcription>what about SU(2)?</transcription>
<note>Same idea with three generators $J_i=\tfrac12\sigma_i$: every element is $U=e^{-i\theta\,\hat n\cdot\vec J}$, and $[J_i,J_j]=i\epsilon_{ijk}J_k$.</note>]]
local function top(api) return api.UIManager:getTopmostVisibleWidget() end
local function ink(api) return api.plugin("inkai") end
return {
  { wait = 2.5, function(api)
      mock(M1)
      api.pen(api.circle(930, 1022, 350, 74))
  end },
  { wait = 1.5, function(api)
      local c = ink(api).chip
      api.tap(c.rect.x + 20, c.rect.y + c.rect.h / 2)
  end },
  { wait = 3, function(api)
      local h = ink(api).cache.hits[1]
      api.tap(h.rect.x + h.rect.w / 2, h.rect.y + h.rect.h / 2)
  end },
  { wait = 1, function(api)
      mock(M2)
      top(api):ask({ typed = "so X is like a velocity?" })
  end },
  { wait = 3, function(api)
      mock(M3)
      top(api):ask({ typed = "what about SU(2)?" })
  end },
  { wait = 3, function(api)
      api.shot("r1-conversation")
      local v = top(api)
      local b = v.buttons:getButtonById("keyboard")
      api.tap(b.dimen.x + b.dimen.w / 2, b.dimen.y + b.dimen.h / 2)
  end },
  { wait = 1.5, function(api)
      for _i, w in ipairs(api.UIManager._window_stack) do
        if w.widget.setInputText then w.widget:setInputText("and how does this connect to spin?") end
      end
  end },
  { wait = 0.8, function(api)
      api.shot("r2-type-follow-up")
      for _i, w in ipairs(api.UIManager._window_stack) do
        if w.widget.setInputText then api.UIManager:close(w.widget) end
      end
  end },
  { wait = 1, function(api)
      os.remove(mockp)
      for _i, w in ipairs(api.UIManager._window_stack) do
        if w.widget.name == "VirtualKeyboard" then api.UIManager:close(w.widget) end
      end
      local items
      for _i, it in ipairs(ink(api):menuItems()) do
        if it.text_func and it.text_func():find("^Model") then items = it.sub_item_table_func() end
      end
      items.icon = "appbar.tools"
      local TouchMenu = require("ui/widget/touchmenu")
      local Screen = require("device").screen
      api.UIManager:show(TouchMenu:new{ width = Screen:getWidth(), tab_item_table = { items } })
  end },
  { wait = 1, function(api) api.shot("r3-model-menu") end },
}
