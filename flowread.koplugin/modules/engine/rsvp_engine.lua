--[[
RSVPEngine  (v2 — performance optimised)
=========================================
Stateful reading engine. Owns:
  - the flat word array + precomputed per-word metadata (_meta)
  - cached pacing toggle flags (_pacing_*) refreshed on settings change
  - display-time calculation: O(1) after startup (no per-word regex or gsub)
  - chapter navigation (binary search)

Performance notes
  • _meta is built once in new() — O(N) startup cost, O(1) per word advance
  • _pacing_* booleans avoid LuaSettings reads during playback
  • displayTime() is a single multiply+add, no string ops
  • setWPM uses setDeferred (no immediate disk flush)
--]]

local logger = require("logger")

local RSVPEngine = {}
RSVPEngine.__index = RSVPEngine

local WPM_MIN = 60
local WPM_MAX = 800

local SENTENCE_END_PAT = "[%.!%?][\"')%]]*$"
local CLAUSE_BREAK_PAT = "[,;:][\"')%]]*$"
local SCRUB_WORDS      = 50

--- Optimal recognition point: **1-based character index** by word length (byte length `#word`).
--- Pattern matches common RSVP/Spritz-style tables: ORP advances one step every three letters
--- from length 3 onward (lengths 3–5 → 2, 6–8 → 3, 9–11 → 4, …), slightly left of centre.
--- Long words beyond the table use the same closed form.
local MAX_ORP_TABLE_LEN = 80
local ORP_BY_LEN = {}
for n = 1, MAX_ORP_TABLE_LEN do
    if n <= 2 then
        ORP_BY_LEN[n] = 1
    else
        ORP_BY_LEN[n] = 2 + math.floor((n - 3) / 3)
    end
end

-- ── Constructor ──────────────────────────────────────────────────────────────

---@param o table  { words = string[], chapters = table[], settings = Settings }
function RSVPEngine:new(o)
    local obj = setmetatable({}, self)
    obj.words       = o.words    or {}
    obj.chapters    = o.chapters or {}
    obj.settings    = o.settings
    obj.current_idx = 1
    obj.wpm         = obj.settings:get("wpm")

    -- Cache pacing toggles — refreshed via refreshSettingsCache() when
    -- the settings panel closes, avoiding LuaSettings reads during playback.
    obj._pacing_long_words  = obj.settings:get("pacing_long_words")
    obj._pacing_complexity  = obj.settings:get("pacing_complexity")
    obj._pacing_punctuation = obj.settings:get("pacing_punctuation")

    -- Pre-compute per-word metadata once at load time.
    -- After this, currentWordInfo() and displayTime() are O(1) table reads.
    obj._meta = {}
    for i, word in ipairs(obj.words) do
        obj._meta[i] = {
            orp_idx            = obj:_orpIndex(word),
            is_sentence_end    = word:match(SENTENCE_END_PAT) ~= nil,
            is_clause_end      = word:match(CLAUSE_BREAK_PAT)  ~= nil,
            long_factor        = (#word > 8)                        and 0.20 or 0,
            complexity_factor  = (obj:_estimateSyllables(word) >= 3) and 0.15 or 0,
            punctuation_factor = obj:_punctuationFactor(word),
        }
    end

    logger.info(string.format("RSVPEngine: %d words, %d chapters, %d WPM",
                              #obj.words, #obj.chapters, obj.wpm))
    return obj
end

-- ── Current word info ────────────────────────────────────────────────────────

---Returns a descriptor for the word at current_idx, or nil at end of book.
---O(1): reads from precomputed _meta; no regex or arithmetic.
---@return table|nil
function RSVPEngine:currentWordInfo()
    local i = self.current_idx
    if i < 1 or i > #self.words then return nil end
    local m = self._meta[i]
    return {
        text            = self.words[i],
        orp_idx         = m.orp_idx,
        is_sentence_end = m.is_sentence_end,
        is_clause_end   = m.is_clause_end,
        prev_word       = i > 1           and self.words[i - 1] or nil,
        next_word       = i < #self.words and self.words[i + 1] or nil,
        index           = i,
        total           = #self.words,
    }
end

-- ── Advance / rewind ─────────────────────────────────────────────────────────

function RSVPEngine:advance()
    if self.current_idx >= #self.words then return false end
    self.current_idx = self.current_idx + 1
    return true
end

function RSVPEngine:rewind()
    if self.current_idx <= 1 then return false end
    self.current_idx = self.current_idx - 1
    return true
end

function RSVPEngine:rewindSentence()
    if self.current_idx <= 1 then self.current_idx = 1; return end
    -- Use precomputed is_sentence_end from _meta
    local idx = self.current_idx - 1
    while idx > 1 do
        if self._meta[idx].is_sentence_end then
            self.current_idx = idx + 1
            return
        end
        idx = idx - 1
    end
    self.current_idx = 1
end

function RSVPEngine:scrubForward()
    self.current_idx = math.min(#self.words, self.current_idx + SCRUB_WORDS)
end

function RSVPEngine:scrubBackward()
    self.current_idx = math.max(1, self.current_idx - SCRUB_WORDS)
end

function RSVPEngine:seekTo(idx)
    self.current_idx = math.max(1, math.min(#self.words, math.floor(idx)))
end

-- ── WPM control ──────────────────────────────────────────────────────────────

---Flush is intentionally deferred; WPM is persisted on the next position save.
function RSVPEngine:setWPM(wpm)
    self.wpm = math.max(WPM_MIN, math.min(WPM_MAX, wpm))
    self.settings:setDeferred("wpm", self.wpm)
end

function RSVPEngine:increaseWPM(step)
    self:setWPM(self.wpm + (step or 10))
end

function RSVPEngine:decreaseWPM(step)
    self:setWPM(self.wpm - (step or 10))
end

-- ── Display time ─────────────────────────────────────────────────────────────

---Returns display time in seconds for the current word.
---O(1): table read + 3 conditional adds + 2 arithmetic ops. No string ops.
function RSVPEngine:displayTime()
    local meta = self._meta[self.current_idx]
    if not meta then return 0.3 end
    local f = 1.0
    if self._pacing_long_words  then f = f + meta.long_factor end
    if self._pacing_complexity  then f = f + meta.complexity_factor end
    if self._pacing_punctuation then f = f + meta.punctuation_factor end
    return (60 / self.wpm) * f
end

-- ── Settings cache refresh ───────────────────────────────────────────────────

---Called by the screen widget after the settings panel closes.
---Updates pacing booleans from the render cache (rc) so playback never reads
---LuaSettings per word. Falls back to direct settings:get if rc is nil.
function RSVPEngine:refreshSettingsCache(rc)
    if rc then
        self._pacing_long_words  = rc.pacing_long_words
        self._pacing_complexity  = rc.pacing_complexity
        self._pacing_punctuation = rc.pacing_punctuation
    else
        self._pacing_long_words  = self.settings:get("pacing_long_words")
        self._pacing_complexity  = self.settings:get("pacing_complexity")
        self._pacing_punctuation = self.settings:get("pacing_punctuation")
    end
end

-- ── Progress ─────────────────────────────────────────────────────────────────

function RSVPEngine:progress()
    if #self.words == 0 then return 0 end
    return (self.current_idx - 1) / #self.words
end

function RSVPEngine:minutesRemaining()
    local words_left = math.max(0, #self.words - self.current_idx)
    return words_left / self.wpm
end

-- ── Chapter navigation ───────────────────────────────────────────────────────

function RSVPEngine:currentChapter()
    if not self.chapters or #self.chapters == 0 then return nil end
    local lo, hi, result = 1, #self.chapters, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if self.chapters[mid].start_idx <= self.current_idx then
            result = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    if result then return self.chapters[result], result end
    return nil
end

function RSVPEngine:chapterCount()
    return self.chapters and #self.chapters or 0
end

function RSVPEngine:jumpToChapter(n)
    if not self.chapters or n < 1 or n > #self.chapters then return end
    self.current_idx = self.chapters[n].start_idx
end

-- ── Internal helpers ─────────────────────────────────────────────────────────

---1-based ORP index (RSVP focus letter). Index is in **Lua byte positions** (`string.sub`),
---so ASCII words line up with “letters”; UTF-8 multi-byte characters use multiple bytes.
function RSVPEngine:_orpIndex(word)
    if not word or #word == 0 then return 1 end
    local n = #word
    if n <= MAX_ORP_TABLE_LEN then
        return ORP_BY_LEN[n]
    end
    local idx = 2 + math.floor((n - 3) / 3)
    if idx > n then return n end
    if idx < 1 then return 1 end
    return idx
end

function RSVPEngine:_estimateSyllables(word)
    local clean = word:lower():gsub("[^a-z]", "")
    local count = 0
    for _ in clean:gmatch("[aeiou]+") do count = count + 1 end
    return math.max(1, count)
end

---Classify the punctuation pause factor for a word.
---Called once per word at construction time; result stored in _meta.
function RSVPEngine:_punctuationFactor(word)
    if word:match(SENTENCE_END_PAT) then return 0.50 end
    if word:match(CLAUSE_BREAK_PAT) then return 0.25 end
    return 0
end

return RSVPEngine
