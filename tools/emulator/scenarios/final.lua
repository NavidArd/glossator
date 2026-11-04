local DataStorage = require("datastorage")
local MOCK = [[<transcription>Circled the limit formula and wrote "why?"</transcription>
<note>Each tiny step multiplies by $\left(I+\frac{\theta}{N}X\right)$. Compounding $N\to\infty$ of them is exactly how $e^{x}$ is defined, so $g(\theta)=e^{\theta X}$.</note>
<more>Think of compound interest: $\left(1+\frac{r}{N}\right)^N \to e^{r}$. Here the "rate" is the generator $X$ and the "time" is the angle $\theta$. Expanding the power with the binomial theorem and letting $N\to\infty$ gives
$$e^{\theta X}=\sum_{n=0}^{\infty}\frac{(\theta X)^n}{n!}=I+\theta X+\frac{\theta^2X^2}{2}+\dots$$
For plane rotations $X^2=-I$, so the series splits into $\cos\theta\, I+\sin\theta\, X$, which is exactly the matrix $R(\theta)$ above.</more>]]
-- "why?" as pen strokes in a 1x1 box per letter
local W = { 0,0, 0.2,1, 0.4,0.35, 0.6,1, 0.8,0 }
local H = { 0,-0.6, 0,1 }
local H2 = { 0,0.45, 0.25,0.3, 0.5,0.45, 0.5,1 }
local Y1 = { 0,0, 0.25,0.6, 0.5,0 }
local Y2 = { 0.5,0, 0.2,1.0, 0.0,1.25 }
local Q = { 0,0.05, 0.15,-0.15, 0.4,-0.15, 0.5,0.1, 0.25,0.4, 0.25,0.65 }
local QD = { 0.25,0.95, 0.27,0.97 }
local function word(api, ox, oy, s)
    local letters = { { W, 0 }, { H, 1.0 }, { H2, 1.0 }, { Y1, 1.7 }, { Y2, 1.7 }, { Q, 2.5 }, { QD, 2.5 } }
    for _, l in ipairs(letters) do
        local pts = {}
        local st, dx = l[1], l[2]
        for i = 1, #st, 2 do
            pts[#pts + 1] = math.floor(ox + (st[i] + dx) * s)
            pts[#pts + 1] = math.floor(oy + st[i + 1] * s)
        end
        api.pen(pts)
    end
end
return {
  { wait = 2.5, function(api) api.shot("0-page") end },
  { wait = 0.5, function(api)
      api.pen(api.circle(930, 1022, 350, 74))
      word(api, 1300, 985, 34)
  end },
  { wait = 1.5, function(api) api.shot("1-ink-and-chip") end },
  { wait = 0.2, function(api)
      local f = io.open(DataStorage:getDataDir() .. "/inkai_mock.txt", "w"); f:write(MOCK); f:close()
      local c = api.plugin("inkai").chip
      api.tap(c.rect.x + 30, c.rect.y + c.rect.h / 2)
  end },
  { wait = 0.4, function(api) api.shot("2-thinking") end },
  { wait = 3, function(api) api.shot("3-answer") end },
  { wait = 0.3, function(api)
      local hits = api.plugin("inkai").cache.hits
      local h = hits[1].rect
      api.tap(h.x + h.w / 2, h.y + h.h / 2)
  end },
  { wait = 1, function(api) api.shot("4-expanded") end },
  { wait = 0.3, function(api) api.tap(930, 2300) end },
  { wait = 1, function(api) api.tap(900, 100) end },
  { wait = 1.5, function(api) api.shot("5-bars") end },
  { wait = 0.3, function(api) local r = api.plugin("kindleui").bars.hits[2].rect; api.tap(r.x + r.w / 2, r.y + r.h / 2) end },
  { wait = 1.5, function(api) api.shot("6-ai-menu") end },
}
