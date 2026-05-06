--[[
DocumentParser  (v2)
====================
Extracts a structured reading result from supported file formats.

Return type (on success):
  { words = string[], chapters = {title, start_idx}[] }, nil

Return type (on error):
  nil, error_string

Supported formats: .epub .txt .md .markdown .fb2 .html .htm .xhtml

EPUB files are parsed via the OPF spine for correct chapter order.
Each spine item that contributes words becomes one chapter entry.

FB2 and HTML files fall back to the same HTML-stripping pipeline.
--]]

local logger = require("logger")

local DocumentParser = {}

-- ── Public entry point ──────────────────────────────────────────────────────

---@param file_path string  absolute path to the book
---@return table|nil, string|nil
function DocumentParser:parse(file_path)
    local ext = file_path:match("%.([^%.]+)$")
    if not ext then
        return nil, "Unknown file extension"
    end
    ext = ext:lower()

    -- EPUB path returns {words, chapters} directly
    if ext == "epub" then
        return self:_parseEpub(file_path)
    end

    -- All other formats produce a raw-text string first, then tokenise
    local raw_text, err
    if ext == "txt" or ext == "md" or ext == "markdown" then
        raw_text, err = self:_readTextFile(file_path)
    elseif ext == "fb2" then
        raw_text, err = self:_parseFB2(file_path)
    elseif ext == "html" or ext == "htm" or ext == "xhtml" then
        raw_text, err = self:_parseHTML(file_path)
    else
        return nil, "Unsupported format: " .. ext
    end

    if not raw_text then
        return nil, err or "Failed to read file"
    end

    local words = self:_tokenize(raw_text)
    if #words == 0 then
        return nil, "No readable text found in file"
    end
    -- Single-section formats have no chapter metadata
    return { words = words, chapters = {} }
end

-- ── Plain-text / Markdown ───────────────────────────────────────────────────

function DocumentParser:_readTextFile(path)
    local f, err = io.open(path, "r")
    if not f then
        return nil, "Cannot open file: " .. (err or path)
    end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then
        return nil, "File is empty"
    end
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    return content
end

-- ── HTML / XHTML ────────────────────────────────────────────────────────────

function DocumentParser:_parseHTML(path)
    local content, err = self:_readTextFile(path)
    if not content then return nil, err end
    return self:_stripHTML(content)
end

-- ── FictionBook 2 (FB2) ─────────────────────────────────────────────────────

function DocumentParser:_parseFB2(path)
    local content, err = self:_readTextFile(path)
    if not content then return nil, err end
    -- FB2 is well-formed XML; the _stripHTML pipeline handles it cleanly
    -- Extract only the <body> section to skip metadata/cover notes
    local body = content:match("<body[^>]*>(.-)</body>")
    return self:_stripHTML(body or content)
end

-- ── EPUB ─────────────────────────────────────────────────────────────────────

function DocumentParser:_parseEpub(path)
    -- Step 1: locate the OPF via container.xml
    local container = self:_unzipRead(path, "META-INF/container.xml")
    if not container then
        return nil, "Cannot read epub container"
    end

    local opf_path = container:match('full%-path="([^"]+)"')
                  or container:match("full%-path='([^']+)'")
    if not opf_path then
        return nil, "Cannot find OPF path in container.xml"
    end

    -- Step 2: parse OPF
    local opf = self:_unzipRead(path, opf_path)
    if not opf then
        return nil, "Cannot read OPF: " .. opf_path
    end

    local opf_dir = opf_path:match("^(.+/)") or ""

    -- Step 3: manifest id → href map (handles both self-closing and paired tags)
    local manifest = {}
    local function add_manifest_entry(attrs)
        local id   = attrs:match('id="([^"]+)"')   or attrs:match("id='([^']+)'")
        local href = attrs:match('href="([^"]+)"')  or attrs:match("href='([^']+)'")
        if id and href then
            manifest[id] = opf_dir .. href
        end
    end
    for attrs in opf:gmatch("<item ([^>]+)/>") do add_manifest_entry(attrs) end
    for attrs in opf:gmatch("<item ([^>]+)></item>") do add_manifest_entry(attrs) end

    -- Step 4: spine order
    local spine_ids = {}
    for idref in opf:gmatch('<itemref[^>]+idref="([^"]+)"') do
        table.insert(spine_ids, idref)
    end
    for idref in opf:gmatch("<itemref[^>]+idref='([^']+)'") do
        table.insert(spine_ids, idref)
    end
    if #spine_ids == 0 then
        for _, href in pairs(manifest) do
            if href:match("%.x?html?$") then
                table.insert(spine_ids, href)
            end
        end
    end

    -- Step 5: extract text + build chapter list
    local all_words = {}
    local chapters  = {}

    for _, idref in ipairs(spine_ids) do
        local href = manifest[idref] or idref
        if href then
            local html = self:_unzipRead(path, href)
            if html then
                local text = self:_stripHTML(html)
                local item_words = self:_tokenize(text)
                if #item_words > 0 then
                    local ch_title = self:_extractChapterTitle(html, #chapters + 1)
                    table.insert(chapters, {
                        title     = ch_title,
                        start_idx = #all_words + 1,
                    })
                    for _, w in ipairs(item_words) do
                        table.insert(all_words, w)
                    end
                else
                    logger.dbg("FlowRead: no words in spine item: " .. href)
                end
            else
                logger.warn("FlowRead: could not read spine item: " .. href)
            end
        end
    end

    if #all_words == 0 then
        return nil, "No readable content found in epub"
    end

    logger.info(string.format("FlowRead: epub → %d words, %d chapters",
                              #all_words, #chapters))
    return { words = all_words, chapters = chapters }
end

-- Try to extract a human-readable title from an HTML/XHTML spine item.
-- Falls back to "Chapter N".
function DocumentParser:_extractChapterTitle(html, n)
    local candidates = {
        html:match("<title[^>]*>([^<]+)</title>"),
        html:match("<h1[^>]*>([^<]+)</h1>"),
        html:match("<h2[^>]*>([^<]+)</h2>"),
        html:match("<h3[^>]*>([^<]+)</h3>"),
    }
    for _, t in ipairs(candidates) do
        if t then
            t = t:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
            if t ~= "" then return t end
        end
    end
    return "Chapter " .. n
end

-- ── ZIP helper ───────────────────────────────────────────────────────────────

function DocumentParser:_unzipRead(zip_path, inner_path)
    local zp = zip_path:gsub("'", "'\\''")
    local ip = inner_path:gsub("'", "'\\''")
    local cmd = string.format("unzip -p '%s' '%s' 2>/dev/null", zp, ip)
    local handle = io.popen(cmd)
    if not handle then return nil end
    local content = handle:read("*all")
    handle:close()
    if not content or content == "" then return nil end
    return content
end

-- ── Tag-block remover (no .* or .- patterns to avoid C stack overflow) ───────

-- Removes all content between matching open and close tags using plain string
-- search. Safe on large HTML files where Lua's pattern engine would overflow.
local function removeTagBlock(html, tag)
    local open_lo  = "<"  .. tag:lower()
    local open_hi  = "<"  .. tag:upper()
    local close_lo = "</" .. tag:lower()
    local close_hi = "</" .. tag:upper()
    local result, pos = {}, 1
    while pos <= #html do
        local s1 = html:find(open_lo, pos, true)
        local s2 = html:find(open_hi, pos, true)
        local start = (s1 and s2) and math.min(s1, s2) or s1 or s2
        if not start then
            result[#result + 1] = html:sub(pos)
            break
        end
        result[#result + 1] = html:sub(pos, start - 1)
        local e1 = html:find(close_lo, start, true)
        local e2 = html:find(close_hi, start, true)
        local cs = (e1 and e2) and math.min(e1, e2) or e1 or e2
        if not cs then break end
        local ce = html:find(">", cs, true)
        if not ce then break end
        pos = ce + 1
    end
    return table.concat(result)
end

-- ── HTML → plain-text ────────────────────────────────────────────────────────

function DocumentParser:_stripHTML(html)
    if not html or html == "" then return "" end

    html = html:gsub("<%?xml[^>]*%?>", "")
    html = html:gsub("<!DOCTYPE[^>]*>", "")
    -- Remove XML/HTML comments using plain search (avoids .* stack overflow)
    do
        local result, pos = {}, 1
        while pos <= #html do
            local s = html:find("<!--", pos, true)
            if not s then result[#result + 1] = html:sub(pos); break end
            result[#result + 1] = html:sub(pos, s - 1)
            local e = html:find("-->", s + 4, true)
            pos = e and (e + 3) or (#html + 1)
        end
        html = table.concat(result)
    end

    html = removeTagBlock(html, "script")
    html = removeTagBlock(html, "style")

    local block = { "p","div","h1","h2","h3","h4","h5","h6",
                    "li","tr","td","th","blockquote","section",
                    "article","header","footer","nav","aside","title" }
    for _, tag in ipairs(block) do
        html = html:gsub("<" .. tag .. "[^>]*>", "\n")
        html = html:gsub("</" .. tag .. "%s*>", "\n")
        local u = tag:upper()
        html = html:gsub("<" .. u .. "[^>]*>", "\n")
        html = html:gsub("</" .. u .. "%s*>", "\n")
    end
    html = html:gsub("<[Bb][Rr][^>]*>", "\n")
    html = html:gsub("<[^>]+>", "")

    html = html:gsub("&amp;",   "&")
    html = html:gsub("&lt;",    "<")
    html = html:gsub("&gt;",    ">")
    html = html:gsub("&quot;",  '"')
    html = html:gsub("&apos;",  "'")
    html = html:gsub("&nbsp;",  " ")
    html = html:gsub("&mdash;", "\xe2\x80\x94")
    html = html:gsub("&ndash;", "\xe2\x80\x93")
    html = html:gsub("&lsquo;", "\xe2\x80\x98")
    html = html:gsub("&rsquo;", "\xe2\x80\x99")
    html = html:gsub("&ldquo;", "\xe2\x80\x9c")
    html = html:gsub("&rdquo;", "\xe2\x80\x9d")
    html = html:gsub("&#(%d+);", function(n)
        local cp = tonumber(n)
        if cp and cp >= 32 and cp < 127 then return string.char(cp) end
        return " "
    end)
    html = html:gsub("&#x(%x+);", function(h)
        local cp = tonumber(h, 16)
        if cp and cp >= 32 and cp < 127 then return string.char(cp) end
        return " "
    end)

    html = html:gsub("[ \t]+", " ")
    html = html:gsub("\n[ \t]+", "\n")
    html = html:gsub("[ \t]+\n", "\n")
    html = html:gsub("\n\n\n+", "\n\n")
    html = html:gsub("^\n+", "")
    html = html:gsub("\n+$", "")
    return html
end

-- ── Tokeniser ────────────────────────────────────────────────────────────────

function DocumentParser:_tokenize(text)
    if not text or text == "" then return {} end
    local words = {}

    for raw in text:gmatch("[^%s]+") do
        local word = raw:gsub('^[%(%)%[%]{}"\xe2\x80\x9c\xe2\x80\x9d\xe2\x80\x98\xe2\x80\x99]+', "")
        word = word:gsub('[%(%)%[%]{}"\xe2\x80\x9c\xe2\x80\x9d\xe2\x80\x98\xe2\x80\x99]+$', "")
        if word ~= "" and word ~= "-" and word ~= "\xe2\x80\x94" then
            table.insert(words, word)
        end
    end

    logger.info(string.format("FlowRead: tokenised %d words", #words))
    return words
end

return DocumentParser
