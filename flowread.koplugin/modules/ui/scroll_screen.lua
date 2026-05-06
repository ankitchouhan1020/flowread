--[[
ScrollScreen  (v2 — performance optimised)
==========================================
Page-scroll reading mode. Extends RSVPScreen so all playback control,
gesture handling, position saving, and colour initialisation are inherited.
Only the painting path is overridden.

Layout:
  ┌────────────────────────────────────────┐
  │  > 250 WPM        Chapter 3           │  ← inherited status bar (28px)
  ├────────────────────────────────────────┤
  │                                        │
  │  ...dim context lines above...         │
  │                                        │
  │  full-brightness line [WORD] ...       │  ← current word at 42% height
  │                                        │
  │  ...dim context lines below...         │
  │                                        │
  ├────────────────────────────────────────┤
  │  ████████░░░░  34%  · 8m              │  ← inherited progress bar (22px)
  └────────────────────────────────────────┘

Performance notes (O1 + O4)
  • _initColors() extends RSVPScreen._initColors to populate scroll-specific
    _rc fields (font, line height, space width) and create a fresh TextLayout
    word-width cache. Both are invalidated automatically on settings change.
  • _buildLines() delegates word-width measurement to the TextLayout cache.
    After the first pass, ~99% of widths for a ±200-word window are cached
    because only ~1 new word enters the window per advance.
  • _paintScrollLine() uses pre-measured widths for ORP parts; does not rely
    on the return value of _renderTrackedText (O5).
--]]

local RenderText = require("ui/rendertext")
local _          = require("gettext")

-- Inherit everything from RSVPScreen
local RSVPScreen  = require("modules/ui/rsvp_screen")
local TextLayout  = require("modules/engine/text_layout")

-- Font sizes for scroll mode (smaller than RSVP: room for multiple lines)
local SCROLL_FONT_MAP = { small = 17, medium = 21, large = 27 }

-- Screen margin (pixels from left/right edges)
local MARGIN = 10

-- Words to render before/after the current word (caps the scan range)
local CONTEXT_WORDS = 200

-- The current line is anchored at this fraction of the word-area height
local ANCHOR_FRAC = 0.42

-- Line height as a multiple of font size
local LINE_GAP_RATIO = 1.65

local ScrollScreen = RSVPScreen:extend{
    name = "scroll_screen",
}

-- ── Font helper ──────────────────────────────────────────────────────────────

function ScrollScreen:_getScrollFontPt()
    return SCROLL_FONT_MAP[self.settings:get("font_size")] or 21
end

-- ── Colour + session cache (O1) ──────────────────────────────────────────────

---Extends the parent _initColors to add scroll-mode render-cache fields and
---a fresh TextLayout word-width cache (O4). Called on init and on every
---settings-panel close so all cached values stay in sync.
function ScrollScreen:_initColors()
    RSVPScreen._initColors(self)

    local font_pt = self:_getScrollFontPt()
    local face    = self:_getFace(font_pt)
    local space_w = RenderText:sizeUtf8Text(0, 9999, face, " ", false, false).x

    -- Extend the parent render cache with scroll-specific values
    self._rc.scroll_font_pt  = font_pt
    self._rc.scroll_face     = face
    self._rc.scroll_line_h   = math.floor(font_pt * LINE_GAP_RATIO)
    self._rc.scroll_space_w  = space_w

    -- Word-width cache: keyed by word string. Recreated here so font/tracking
    -- changes automatically invalidate it.
    local tracking = self._rc.tracking
    self._text_layout = TextLayout:new{
        measure = function(text)
            return self:_trackedTextWidth(face, text, tracking)
        end,
    }
end

-- ── Paint override ───────────────────────────────────────────────────────────

function ScrollScreen:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y

    local W = self.dimen.w
    local H = self.dimen.h

    local STATUS_H   = 28
    local PROGRESS_H = 22
    local BOTTOM_PAD = 4

    bb:fill(self.bg_color)

    -- Status bar (inherited)
    self:_paintStatus(bb, W)
    bb:paintRect(0, STATUS_H, W, 1, self.dim_color)

    -- Scrolling text area
    local area_y = STATUS_H + 1
    local area_h = H - STATUS_H - 1 - PROGRESS_H - BOTTOM_PAD - 1
    self:_paintScrollArea(bb, W, area_y, area_h)

    -- Progress bar (inherited)
    local prog_y    = H - PROGRESS_H - BOTTOM_PAD
    bb:paintRect(0, prog_y - 1, W, 1, self.dim_color)
    self:_paintProgress(bb, W, prog_y, self.engine:currentWordInfo())
end

-- ── Scroll area ──────────────────────────────────────────────────────────────

function ScrollScreen:_paintScrollArea(bb, W, area_y, area_h)
    local rc = self._rc

    local lines, cur_line_idx = self:_buildLines(W)
    if not cur_line_idx then return end

    local anchor_baseline = area_y + math.floor(area_h * ANCHOR_FRAC)
                          + math.floor(rc.scroll_font_pt * 0.75)

    for li, line in ipairs(lines) do
        local rel      = li - cur_line_idx
        local baseline = anchor_baseline + rel * rc.scroll_line_h

        if baseline > area_y + rc.scroll_font_pt and baseline < area_y + area_h then
            self:_paintScrollLine(bb, line, baseline, li == cur_line_idx)
        end
    end
end

---Build a list of lines using the word-width cache (O4).
---After warm-up, only ~1 unique word per advance requires a fresh measurement.
---Returns: lines[], current_line_index
function ScrollScreen:_buildLines(W)
    local words   = self.engine.words
    local current = self.engine.current_idx
    local usable  = W - MARGIN * 2
    local space_w = self._rc.scroll_space_w

    local start = math.max(1, current - CONTEXT_WORDS)
    local stop  = math.min(#words, current + CONTEXT_WORDS)

    return self._text_layout:wrap(words, start, stop, current, {
        margin  = MARGIN,
        usable  = usable,
        space_w = space_w,
    })
end

---Render a single line of words.
---Words on the current line use fg_color; other lines use phantom_color.
---The current word gets the ORP highlight treatment.
---Widths for ORP substrings are pre-measured so _renderTrackedText return
---values are not relied on (O5).
function ScrollScreen:_paintScrollLine(bb, line, baseline, is_cur_line)
    local rc          = self._rc
    local face        = rc.scroll_face
    local font_pt     = rc.scroll_font_pt
    local tracking    = rc.tracking
    local style       = rc.style
    local current_idx = self.engine.current_idx

    for _, wd in ipairs(line.words) do
        local is_cur_word = (wd.idx == current_idx)

        if is_cur_word and is_cur_line then
            -- ORP highlight on the current word
            local orp_i  = self.engine:_orpIndex(wd.text)
            local prefix = wd.text:sub(1, orp_i - 1)
            local orp_ch = wd.text:sub(orp_i, orp_i)
            local suffix = wd.text:sub(orp_i + 1)

            local prefix_w = self:_trackedTextWidth(face, prefix, tracking)
            local orp_w    = self:_trackedTextWidth(face, orp_ch, tracking)

            if style == "invert" then
                local px = wd.x_start + prefix_w
                local pad_x, pad_y = 2, 3
                bb:paintRect(px - pad_x, baseline - font_pt - pad_y,
                             orp_w + pad_x * 2, font_pt + pad_y * 2, self.orp_bg)
            end
            if style == "underline" then
                bb:paintRect(wd.x_start + prefix_w, baseline + 2,
                             orp_w, 2, self.accent_color)
            end

            -- Render prefix / ORP / suffix using pre-measured widths (O5).
            local rx = wd.x_start
            if prefix ~= "" then
                self:_renderTrackedText(bb, rx, baseline, face,
                    prefix, false, self.fg_color, tracking)
                rx = rx + prefix_w
            end
            local orp_fg = (style == "invert") and self.orp_fg or self.fg_color
            self:_renderTrackedText(bb, rx, baseline, face,
                orp_ch, (style == "bold"), orp_fg, tracking)
            rx = rx + orp_w
            if suffix ~= "" then
                self:_renderTrackedText(bb, rx, baseline, face,
                    suffix, false, self.fg_color, tracking)
            end
        else
            local color = is_cur_line and self.fg_color or self.phantom_color
            self:_renderTrackedText(bb, wd.x_start, baseline,
                face, wd.text, false, color, tracking)
        end
    end
end

return ScrollScreen
