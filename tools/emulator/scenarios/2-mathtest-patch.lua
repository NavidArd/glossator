-- A user patch for the emulator only: renders LaTeX/handwriting samples to mathtest.png and quits.
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
package.path = "plugins/glossator.koplugin/?.lua;" .. package.path
UIManager:scheduleIn(1, function()
    local Rich = require("glossator/rich")
    local Math = require("glossator/math")
    local W, H = 1400, 2400
    local bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    local samples = {
        "Noether: if $L$ doesn't change under $q\\to q+\\epsilon\\,\\delta q$, then $Q=\\frac{\\partial L}{\\partial \\dot q}\\delta q$ is conserved: $\\frac{dQ}{dt}=0$.",
        "The generator is $X = \\frac{dR}{d\\theta}\\big|_{\\theta=0}$, and $e^{\\theta X} = \\sum_{n=0}^{\\infty} \\frac{(\\theta X)^n}{n!}$.",
        "Spin-½: $J_i=\\tfrac12\\sigma_i$, so $[J_i,J_j]=i\\epsilon_{ijk}J_k$ and $e^{2\\pi i J_3}=-I$ → spinors flip sign!",
        "$$\\sigma_2=\\begin{pmatrix}0 & -i\\\\ i & 0\\end{pmatrix},\\quad \\partial_\\mu J^\\mu = 0,\\quad \\hbar\\nabla^2\\psi \\leq \\sqrt{x^2+y^2}$$",
        "Lagrangian $\\mathcal{L}=\\bar\\psi(i\\gamma^\\mu\\partial_\\mu - m)\\psi$, with $\\vec{p}\\cdot\\hat{n}$, $\\int_0^{2\\pi} d\\phi$, $\\mathbb{R}^3$, $\\mathfrak{su}(2)$, $\\left(\\frac{a}{b}\\right)^2 \\neq \\sqrt[3]{x}$.",
    }
    local y = 20
    for i, hand in ipairs({"kalam", "caveat", "patrick"}) do
        for j, s in ipairs(samples) do
            if hand == "kalam" or j <= 2 then
            local L = Rich.layout(s, { width = 620, px = 40, hand = hand })
            bb:paintRect(20, y, 620, 1, Blitbuffer.COLOR_LIGHT_GRAY)
            Rich.paint(L, bb, 20, y + 4, Blitbuffer.COLOR_GRAY_3)
            y = y + L.h + 30
            end
        end
    end
    local y2 = 20
    for _, src in ipairs({"x^2 + y_1^2", "\\frac{1}{2} m v^2", "\\sum_{i=1}^{N} a_i", "\\int_0^\\infty e^{-x^2} dx", "\\sqrt{2}", "\\left[ \\frac{\\partial^2}{\\partial x^2} \\right]", "\\vec{E} = -\\nabla\\phi", "\\langle \\psi | H | \\psi \\rangle", "\\lim_{N\\to\\infty}\\Big(I+\\frac{\\theta}{N}X\\Big)^N"}) do
        for _, disp in ipairs({false, true}) do
            local box = Math.layout(src, 44, disp)
            Math.paint(box, bb, 700 + (disp and 340 or 0), y2 + box.h, Blitbuffer.COLOR_BLACK)
        end
        y2 = y2 + 180
    end
    bb:writePNG((os.getenv("INKAI_SHOTS") or ".") .. "/mathtest.png")
    os.exit(0)
end)
