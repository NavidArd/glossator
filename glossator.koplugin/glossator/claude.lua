--[[--
A minimal client for the models Glossator asks (raw HTTPS, no SDK):

  * Anthropic's Messages API, for Claude with an Anthropic key (sk-ant-...)
  * OpenRouter's chat API (OpenAI-compatible), with an OpenRouter key
    (sk-or-...), for Gemini, GPT, Grok and others, and Claude too

Both get the same system prompt, images and context, and answer in the same
tagged format (see Claude.parse).
]]

local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local Claude = {
    openrouter_endpoint = "https://openrouter.ai/api/v1/chat/completions",
    openrouter_models = "https://openrouter.ai/api/v1/models",
    endpoint = "https://api.anthropic.com/v1/messages",
    api_version = "2026-10-21",
    -- Models that accept server-side refusal fallbacks (fallbacks: "default").
    fallback_models = {
        ["claude-opus-5-5"] = true,
        ["claude-sonnet-5-5"] = true,
    },
}

Claude.system_prompt = [[You are a reading companion living inside an e-ink reader (a Kindle Scribe). While reading, the user writes or circles directly on the book page with a stylus, then asks you about it. Your reply is handwritten into the page's margin next to their ink, like a teacher's note in the margin of a student's book.

You receive the page as it looks now, with their ink on it, then a close-up of the area around the ink. You may also get the page's extracted text. Ignore any small "Ask AI" button.

First transcribe what they wrote (or describe what they marked, e.g. "circled: Noether's theorem"). Work out what on the page the ink points at: a circled formula, an underlined word, an arrow, a question mark. If they wrote a question, answer it. If they only marked something, explain it the way a good teacher would in the margin: the key idea, the step that is not obvious, or why it matters.

Write the margin note like a teacher: direct, warm, and short. At most 35 words, ideally two short sentences. No greeting, no preamble, no markdown, no bullet points.

Write all mathematics in LaTeX between dollar signs, e.g. $\frac{\partial L}{\partial \dot q}$ or $e^{i\theta}$; use $$...$$ only for one important equation on its own line. Supported: ^ _ \frac \sqrt \partial \nabla \int \sum \prod \lim \infty \hbar, Greek letters, \to \Rightarrow \leq \geq \neq \approx \equiv \sim \propto \in \cdot \times \pm \otimes \dagger \langle \rangle, \vec \hat \bar \dot \ddot \tilde, \mathcal \mathbb \mathbf \mathfrak \text, \left( \right), \begin{pmatrix} a & b \\ c & d \end{pmatrix}. Keep formulas compact: the note is a few centimetres wide.

If more explanation would really help, add it separately (at most 150 words, same style and math rules); it is shown when they tap the note.

Reply in exactly this format:
<transcription>what they wrote or marked</transcription>
<note>the short margin note</note>
<more>optional longer explanation, or leave empty</more>]]

local function base64(data)
    local ok, mime = pcall(require, "mime")
    if ok and mime and mime.b64 then
        return (mime.b64(data))
    end
    return require("ffi/sha2").bin_to_base64(data)
end

local function readFile(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return data
end

local function trim(s)
    return s and (s:gsub("^%s+", ""):gsub("%s+$", "")) or s
end

--[[--
Read Claude's reply: { note, more, transcription }, or nil and an error.
]]
function Claude.parse(text, stop_reason)
    text = text or ""
    local transcription = trim(text:match("<transcription>(.-)</transcription>"))
    local note = trim(text:match("<note>(.-)</note>") or text:match("<answer>(.-)</answer>"))
    local more = trim(text:match("<more>(.-)</more>"))
    if not note or note == "" then
        -- no tags at all: the whole reply is the note
        note = trim(text:gsub("<transcription>.-</transcription>", ""):gsub("</?%a+>", ""))
    end
    if not note or note == "" then
        if stop_reason == "max_tokens" then
            return nil, "The answer was cut off (max_tokens)."
        end
        return nil, "Empty answer."
    end
    if more == "" then more = nil end
    return { note = note, more = more, transcription = transcription }
end

--[[--
Ask Claude about a page and a handwritten note.

@param opts table: api_key, model, images (array of PNG paths), context (string), history (array of {question, answer}), mock (a canned raw reply, for testing without the network)
@return { note, more, transcription }  -- or nil, error message
]]
-- KOReader's ssl.https doesn't check certificates (verify = "none"), so on a
-- hostile Wi-Fi anyone in the middle could read the API key. Glossator's
-- requests check the server's certificate against KOReader's CA bundle and its
-- name against the host, and refuse to send anything otherwise.
local http = require("socket.http")
local ssl = require("ssl")
local url_lib = require("socket.url")
Claude.cafile = "data/ca-bundle.crt"

local function hostMatches(pattern, host)
    pattern, host = pattern:lower(), host:lower()
    if pattern == host then return true end
    local rest = pattern:match("^%*%.(.+)$")
    if rest then
        local first, tail = host:match("^([^.]+)%.(.+)$")
        return first ~= nil and tail == rest
    end
    return false
end

-- Whether the certificate is for `host` (its subjectAltName DNS names).
function Claude.certFor(cert, host)
    local ok, exts = pcall(cert.extensions, cert)
    local san = ok and type(exts) == "table" and exts["2.5.29.17"]
    for _i, name in ipairs(san and san.dNSName or {}) do
        if hostMatches(name, host) then return true end
    end
    return false
end

local function secureRequest(reqt)
    local f = io.open(Claude.cafile, "r")
    if not f then return nil, "No CA bundle at " .. Claude.cafile .. ", not sending the key." end
    f:close()
    local host = url_lib.parse(reqt.url).host
    reqt.create = function()
        local conn = { sock = socket.tcp() }
        function conn:settimeout() return self.sock:settimeout(180) end
        function conn:connect(h, port)
            local ok, err = self.sock:connect(h, port)
            if not ok then error(err, 0) end
            local s, werr = ssl.wrap(self.sock, {
                mode = "client", protocol = "any",
                options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
                verify = "peer", cafile = Claude.cafile,
            })
            if not s then error(werr, 0) end
            self.sock = s
            s:sni(host)
            s:settimeout(180)
            local hok, herr = s:dohandshake()
            if not hok then error("TLS: " .. tostring(herr), 0) end
            if not Claude.certFor(s:getpeercertificate(), host) then
                error("TLS: the certificate is not for " .. host, 0)
            end
            local mt = getmetatable(s).__index
            for name, method in pairs(mt) do
                if type(method) == "function" and name ~= "connect" and name ~= "settimeout" then
                    self[name] = function(c, ...) return method(c.sock, ...) end
                end
            end
            return 1
        end
        return conn
    end
    local ok, res, code, headers, status = pcall(http.request, reqt)
    if not ok then return nil, tostring(res) end
    return res, code, headers, status
end

-- POST `body` as JSON to `url`; returns the decoded reply and the HTTP code, or
-- nil and an error.
local function postJSON(url, headers, body)
    local payload = json.encode(body)
    headers["content-type"] = "application/json"
    headers["content-length"] = tostring(#payload)
    local chunks = {}
    socketutil:set_timeout(60, 180)
    local code, _h, status = socket.skip(1, secureRequest{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(chunks),
    })
    socketutil:reset_timeout()
    if type(code) ~= "number" then
        return nil, "Network error: " .. tostring(code or status)
    end
    local raw = table.concat(chunks)
    local ok, resp = pcall(json.decode, raw)
    if not ok or type(resp) ~= "table" then
        logger.warn("Glossator: bad response", code, raw:sub(1, 500))
        return nil, "Unexpected response (HTTP " .. code .. ")"
    end
    return resp, code
end

-- The same question through OpenRouter (OpenAI-style chat completions).
local function askOpenRouter(opts)
    local content = {}
    for _i, path in ipairs(opts.images or {}) do
        local png, err = readFile(path)
        if not png then return nil, "Could not read image: " .. tostring(err) end
        table.insert(content, { type = "image_url", image_url = { url = "data:image/png;base64," .. base64(png) } })
    end
    table.insert(content, { type = "text", text = opts.context })
    local messages = { { role = "system", content = Claude.system_prompt } }
    for _i, turn in ipairs(opts.history or {}) do
        table.insert(messages, { role = "user", content = "Earlier, on this book, I wrote: " .. (turn.question or "(ink)") })
        table.insert(messages, { role = "assistant", content = turn.answer })
    end
    table.insert(messages, { role = "user", content = content })
    local resp, code = postJSON(Claude.openrouter_endpoint, {
        ["authorization"] = "Bearer " .. opts.api_key,
        ["x-title"] = "Glossator",
    }, {
        model = opts.model,
        max_tokens = 12000,
        reasoning = { effort = "low" },
        messages = messages,
    })
    if not resp then return nil, code end
    if code ~= 200 or resp.error then
        local e = resp.error
        local msg = type(e) == "table" and (e.message or json.encode(e)) or tostring(e)
        return nil, "OpenRouter error " .. tostring(code) .. ": " .. tostring(msg)
    end
    local choice = resp.choices and resp.choices[1]
    local msg = choice and choice.message
    local text = msg and msg.content
    if type(text) == "table" then
        local parts = {}
        for _i, part in ipairs(text) do
            if type(part) == "table" and part.text then table.insert(parts, part.text) end
        end
        text = table.concat(parts, "\n")
    end
    if not text or text == "" then
        if choice and choice.finish_reason == "length" then return nil, "The answer was cut off (max_tokens)." end
        return nil, "Empty answer."
    end
    return Claude.parse(text, choice and choice.finish_reason == "length" and "max_tokens" or nil)
end

--[[--
The newest vision models on OpenRouter from the big providers, a few each:
{ { id, name, created } }, newest first, or nil and an error. (No key needed.)
]]
Claude.PROVIDERS = { "anthropic", "openai", "google", "x-ai", "mistralai", "qwen", "deepseek", "meta-llama" }
function Claude.listModels(per_provider)
    per_provider = per_provider or 3
    local chunks = {}
    socketutil:set_timeout(30, 90)
    local code, _h, status = socket.skip(1, secureRequest{
        url = Claude.openrouter_models,
        method = "GET",
        sink = ltn12.sink.table(chunks),
    })
    socketutil:reset_timeout()
    if code ~= 200 then return nil, "Could not load the model list (" .. tostring(code or status) .. ")" end
    local ok, resp = pcall(json.decode, table.concat(chunks))
    if not ok or type(resp) ~= "table" or type(resp.data) ~= "table" then return nil, "Unexpected model list." end
    local by = {}
    for _i, m in ipairs(resp.data) do
        local id = m.id or ""
        local prov = id:match("^([^/]+)/")
        local arch = m.architecture or {}
        local vision = false
        for _j, mod in ipairs(arch.input_modalities or {}) do if mod == "image" then vision = true end end
        local text_out = true
        if arch.output_modalities then
            text_out = false
            for _j, mod in ipairs(arch.output_modalities) do if mod == "text" then text_out = true end end
        end
        if prov and vision and text_out and not id:find(":") and not id:find("guard") and not id:find("image") then
            by[prov] = by[prov] or {}
            table.insert(by[prov], { id = id, name = m.name or id, created = m.created or 0 })
        end
    end
    local out = {}
    for _i, prov in ipairs(Claude.PROVIDERS) do
        local list = by[prov] or {}
        table.sort(list, function(a, b) return a.created > b.created end)
        for k = 1, math.min(per_provider, #list) do table.insert(out, list[k]) end
    end
    return out
end

function Claude.ask(opts)
    if opts.mock then return Claude.parse(opts.mock) end
    if opts.task == "models" then return Claude.listModels() end
    if opts.provider == "openrouter" then return askOpenRouter(opts) end
    local content = {}
    for _i, path in ipairs(opts.images) do
        local png, err = readFile(path)
        if not png then return nil, "Could not read image: " .. tostring(err) end
        table.insert(content, { type = "image", source = { type = "base64", media_type = "image/png", data = base64(png) } })
    end
    table.insert(content, { type = "text", text = opts.context })

    local messages = {}
    for _i, turn in ipairs(opts.history or {}) do
        table.insert(messages, { role = "user", content = "Earlier, on this book, I wrote: " .. (turn.question or "(ink)") })
        table.insert(messages, { role = "assistant", content = turn.answer })
    end
    table.insert(messages, { role = "user", content = content })

    local body = {
        model = opts.model,
        max_tokens = 16000,
        system = Claude.system_prompt,
        output_config = { effort = "low" },
        messages = messages,
    }
    local headers = {
        ["content-type"] = "application/json",
        ["x-api-key"] = opts.api_key,
        ["anthropic-version"] = Claude.api_version,
    }
    if Claude.fallback_models[opts.model] then
        body.fallbacks = "default"
        headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
    end

    local payload = json.encode(body)
    headers["content-length"] = tostring(#payload)

    local chunks = {}
    socketutil:set_timeout(60, 180)
    local code, _, status = socket.skip(1, secureRequest{
        url = Claude.endpoint,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(chunks),
    })
    socketutil:reset_timeout()

    if type(code) ~= "number" then
        return nil, "Network error: " .. tostring(code or status)
    end
    local raw = table.concat(chunks)
    local ok, resp = pcall(json.decode, raw)
    if not ok or type(resp) ~= "table" then
        logger.warn("Glossator: bad response", code, raw)
        return nil, "Unexpected response (HTTP " .. code .. ")"
    end
    if code ~= 200 then
        local msg = resp.error and resp.error.message or raw
        return nil, "API error " .. code .. ": " .. tostring(msg)
    end
    if resp.stop_reason == "refusal" then
        return nil, "Claude declined to answer this one."
    end

    local parts = {}
    for _i, block in ipairs(resp.content or {}) do
        if block.type == "text" and block.text then
            table.insert(parts, block.text)
        end
    end
    local text = table.concat(parts, "\n")
    return Claude.parse(text, resp.stop_reason)
end

return Claude
