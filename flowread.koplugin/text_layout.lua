--[[
TextLayout  (v2 — performance helper)
======================================
Shared word-width cache and line-wrapping helper used by ScrollScreen and
ScrubPreview.

Rationale
---------
ScrollScreen._buildLines and ScrubPreview._paintTextArea each scan a window
of ~160–500 words per word advance, calling sizeUtf8Text() for every word.
On a Kindle iMX6 each call costs ~0.1–0.3 ms, so 400 calls = 40–120 ms.

After the first wrap of a window, every subsequent advance introduces only
~1 new word at the trailing edge; the other 399 words are already cached.
Common prose words (the, a, to, and, in, …) are cached after their first
appearance and hit on almost every subsequent line.

Cache invalidation
------------------
TextLayout is recreated inside _initColors() which is called whenever the
settings panel closes. This covers all font / typeface / tracking changes
without manual invalidation logic.

Usage
-----
    local TextLayout = require("text_layout")

    -- In _initColors():
    self._text_layout = TextLayout:new{
        measure = function(text)
            return self:_trackedTextWidth(face, text, tracking)
        end,
    }

    -- Elsewhere:
    local w = self._text_layout:wordWidth(word)
    local lines, cur_line_idx = self._text_layout:wrap(
        words, start_i, stop_i, current_i,
        { margin = 10, usable = W - 20, space_w = space_w }
    )
--]]

local TextLayout = {}
TextLayout.__index = TextLayout

-- ── Constructor ──────────────────────────────────────────────────────────────

---@param o table  { measure = function(text) -> width }
function TextLayout:new(o)
    return setmetatable({
        _measure = o.measure,
        _cache   = {},
    }, self)
end

-- ── Word-width cache ─────────────────────────────────────────────────────────

---Return the pixel width of `text`, using the cache to avoid repeated
---sizeUtf8Text calls for the same word within a reading session.
---@param text string
---@return number
function TextLayout:wordWidth(text)
    local w = self._cache[text]
    if w == nil then
        w = self._measure(text)
        self._cache[text] = w
    end
    return w
end

-- ── Line wrapping ────────────────────────────────────────────────────────────

---Wrap a slice of `words_arr` into visual lines.
---
---@param words_arr  string[]   flat word list (engine.words)
---@param start_i    number     first index to wrap (inclusive)
---@param stop_i     number     last index to wrap (inclusive)
---@param current_i  number     index of the current (highlighted) word
---@param opts       table      { margin, usable, space_w }
---  opts.margin   left margin in pixels (x_start offset)
---  opts.usable   usable line width in pixels (screen_w - 2*margin)
---  opts.space_w  pixel width of a single space character
---
---@return table[]      lines        array of { words = { text, idx, x_start, width }[] }
---@return number|nil  cur_line_idx  1-based index of the line containing current_i
function TextLayout:wrap(words_arr, start_i, stop_i, current_i, opts)
    local margin  = opts.margin  or 10
    local usable  = opts.usable
    local space_w = opts.space_w

    local lines        = {}
    local cur_line     = { words = {} }
    local line_w       = 0
    local cur_line_idx = nil

    for i = start_i, stop_i do
        local word = words_arr[i]
        local w    = self:wordWidth(word)
        local gap  = (line_w > 0) and space_w or 0
        if line_w > 0 and line_w + gap + w > usable then
            table.insert(lines, cur_line)
            cur_line = { words = {} }
            line_w   = 0
            gap      = 0
        end
        table.insert(cur_line.words, {
            text    = word,
            idx     = i,
            x_start = margin + line_w + gap,
            width   = w,
        })
        line_w = line_w + gap + w
        if i == current_i then cur_line_idx = #lines + 1 end
    end
    if #cur_line.words > 0 then
        table.insert(lines, cur_line)
    end

    -- Fallback: current word may have ended exactly on a line boundary
    if not cur_line_idx then
        for li, line in ipairs(lines) do
            for _, wd in ipairs(line.words) do
                if wd.idx == current_i then
                    cur_line_idx = li
                    break
                end
            end
            if cur_line_idx then break end
        end
    end

    return lines, cur_line_idx
end

return TextLayout
