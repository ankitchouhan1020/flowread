--[[
ScrubPreview  (v2)
==================
Full-screen overlay opened when the user swipes left/right while paused in
RSVP mode. Shows ~9 lines of text centred on the current word so the reader
can quickly browse forward/backward before returning to RSVP playback.

Gesture map:
  tap word           → select that word as current/start position
  tap left footer    → previous page
  tap centre footer  → return to RSVP/start selector
  tap right footer   → next page
  hardware Back      → return to RSVP
  hardware Back      → same as tap
--]]

local ok_input, InputContainer = pcall(require, "ui/widget/container/inputcontainer")
if not ok_input then
    InputContainer = require("ui/widget/inputcontainer")
end
local GestureRange   = require("ui/gesturerange")
local UIManager      = require("ui/uimanager")
local Device         = require("device")
local Screen         = Device.screen
local Geom           = require("ui/geometry")
local Font           = require("ui/font")
local RenderText     = require("ui/rendertext")
local Blitbuffer     = require("ffi/blitbuffer")
local _              = require("gettext")

-- Preview uses smaller, reader-appropriate font sizes
local FONT_MAP = { small = 16, medium = 20, large = 26 }
local MARGIN       = 10
-- Reduced from 250 to 80: enough for ~12 visible lines at 20pt on 600px wide
-- screen, while cutting the scan window from 500 to 160 words per page.
local CONTEXT_WORDS = 80
local ANCHOR_FRAC  = 0.42
local LINE_GAP     = 1.65
local PAGE_WORDS    = 80

-- Re-use typography helpers from RSVPScreen and the shared layout cache.
local RSVPScreen = require("modules/ui/rsvp_screen")
local TextLayout  = require("modules/engine/text_layout")

local ScrubPreview = InputContainer:extend{
    name = "scrub_preview",
}

-- ── Lifecycle ────────────────────────────────────────────────────────────────

function ScrubPreview:init()
    -- self.engine, self.settings, self.on_close, self.on_select already set by new{...}

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    self:_initColors()

    self.ges_events = {
        Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen }
        },
    }

    if Device:hasKeys() then
        self.key_events = {
            Close = { { "Back" }, doc = "close scrub preview" },
        }
    end
end

function ScrubPreview:onShow()
    UIManager:setDirty(self, "full")
end

-- ── Colour theme + render cache (mirrors RSVPScreen._initColors) ─────────────

function ScrubPreview:_initColors()
    if self.settings:get("theme") == "dark" then
        self.bg_color      = Blitbuffer.COLOR_BLACK
        self.fg_color      = Blitbuffer.COLOR_WHITE
        self.dim_color     = Blitbuffer.COLOR_GREY
        self.phantom_color = Blitbuffer.COLOR_GREY
        self.orp_bg        = Blitbuffer.COLOR_WHITE
        self.orp_fg        = Blitbuffer.COLOR_BLACK
        self.accent_color  = Blitbuffer.COLOR_WHITE
        self.overlay_color = Blitbuffer.COLOR_BLACK
    else
        self.bg_color      = Blitbuffer.COLOR_WHITE
        self.fg_color      = Blitbuffer.COLOR_BLACK
        self.dim_color     = Blitbuffer.COLOR_GREY
        self.phantom_color = Blitbuffer.COLOR_GREY
        self.orp_bg        = Blitbuffer.COLOR_BLACK
        self.orp_fg        = Blitbuffer.COLOR_WHITE
        self.accent_color  = Blitbuffer.COLOR_BLACK
        self.overlay_color = Blitbuffer.COLOR_WHITE
    end

    -- Session-stable render values (O7): rebuilt when settings change.
    local font_pt  = FONT_MAP[self.settings:get("font_size")] or 20
    local tracking = self.settings:get("letter_spacing") or 0
    local face     = self:_getFace(font_pt)
    local space_w  = RenderText:sizeUtf8Text(0, 9999, face, " ", true, false).x

    self._preview_font_pt   = font_pt
    self._preview_tracking  = tracking
    self._preview_face      = face
    self._preview_space_w   = space_w
    self._preview_style     = self.settings:get("anchor_style")
    self._preview_hface     = self:_getFace(16)

    -- Word-width cache via shared TextLayout module (O7).
    -- Recreating here automatically invalidates on font/tracking changes.
    self._text_layout = TextLayout:new{
        measure = function(text)
            return self:_trackedTextWidth(face, text, tracking)
        end,
    }
end

-- ── Rendering ────────────────────────────────────────────────────────────────

function ScrubPreview:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y

    local W = self.dimen.w
    local H = self.dimen.h

    bb:fill(self.bg_color)
    self._word_hits = {}

    -- Header bar
    local STATUS_H = 36
    local info  = self.engine:currentWordInfo()
    local ch, current_n = self.engine:currentChapter()
    local hint  = self.select_mode and _("Select start word")
               or (ch and ch.title or _("Scrub Preview"))
    local pos_str = info and string.format("%d / %d", info.index, info.total) or ""

    local hface = self._preview_hface
    RenderText:renderUtf8Text(bb, 8, 22, hface, _("Back"),
        true, false, self.fg_color)
    if #hint > 34 then hint = hint:sub(1, 31) .. "..." end
    local hint_w = RenderText:sizeUtf8Text(0, W, hface, hint, true, false).x
    RenderText:renderUtf8Text(bb, math.floor((W - hint_w) / 2), 22, hface, hint,
        true, false, self.dim_color)
    local ps_w = RenderText:sizeUtf8Text(0, W, hface, pos_str, true, false).x
    RenderText:renderUtf8Text(bb, W - ps_w - 8, 22, hface, pos_str,
        true, false, self.dim_color)
    bb:paintRect(0, STATUS_H, W, 1, self.dim_color)

    -- Paginated footer
    local FOOTER_H = 32
    bb:paintRect(0, H - FOOTER_H - 1, W, 1, self.dim_color)
    RenderText:renderUtf8Text(bb, 8, H - 9, hface, _("Prev"),
        true, false, self.fg_color)
    local return_text = self.select_mode and _("Back") or _("Return")
    local return_w = RenderText:sizeUtf8Text(0, W, hface, return_text, true, false).x
    RenderText:renderUtf8Text(bb, math.floor((W - return_w) / 2), H - 9,
        hface, return_text, true, false, self.fg_color)
    local next_text = _("Next")
    local next_w = RenderText:sizeUtf8Text(0, W, hface, next_text, true, false).x
    RenderText:renderUtf8Text(bb, W - next_w - 8, H - 9,
        hface, next_text, true, false, self.fg_color)

    -- Text area between header and footer
    local area_y = STATUS_H + 1
    local area_h = H - STATUS_H - 1 - FOOTER_H - 1
    self:_paintTextArea(bb, W, area_y, area_h)
end

function ScrubPreview:_paintTextArea(bb, W, area_y, area_h)
    -- Use session-stable cached values (O7); avoids per-paint settings reads.
    local font_pt  = self._preview_font_pt
    local face     = self._preview_face
    local tracking = self._preview_tracking
    local style    = self._preview_style
    local line_h   = math.floor(font_pt * LINE_GAP)
    local usable   = W - MARGIN * 2

    local words   = self.engine.words
    local current = self.engine.current_idx
    local start   = math.max(1, current - CONTEXT_WORDS)
    local stop    = math.min(#words, current + CONTEXT_WORDS)

    -- Line wrapping via shared cached TextLayout (O7).
    local lines, cur_line_idx = self._text_layout:wrap(
        words, start, stop, current,
        { margin = MARGIN, usable = usable, space_w = self._preview_space_w }
    )
    if not cur_line_idx then return end

    local anchor_baseline = area_y + math.floor(area_h * ANCHOR_FRAC)
                          + math.floor(font_pt * 0.75)

    for li, line in ipairs(lines) do
        local rel      = li - cur_line_idx
        local baseline = anchor_baseline + rel * line_h
        if baseline > area_y + font_pt and baseline < area_y + area_h then
            local is_cur_line = (li == cur_line_idx)
            for __, wd in ipairs(line.words) do
                local is_cur = (wd.idx == current)
                table.insert(self._word_hits, {
                    idx = wd.idx,
                    x = wd.x_start,
                    y = baseline - font_pt,
                    w = math.max(1, wd.width),
                    h = math.floor(line_h * 0.95),
                })

                if is_cur and is_cur_line then
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

                    -- Render using pre-measured widths; do not rely on return
                    -- value of _renderTrackedText (O5).
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
    end
end

-- Borrow typography helpers from RSVPScreen (they are pure functions bound
-- to RSVPScreen; calling them via self works because Lua looks up methods
-- on the metatable chain – but ScrubPreview doesn't extend RSVPScreen.
-- We add them as direct method references instead.)

ScrubPreview._getFace            = RSVPScreen._getFace
ScrubPreview._trackedTextWidth   = RSVPScreen._trackedTextWidth
ScrubPreview._renderTrackedText  = RSVPScreen._renderTrackedText

-- ── Gesture handlers ─────────────────────────────────────────────────────────

function ScrubPreview:onTap(_, ges)
    if not ges or not ges.pos then return true end
    local x = ges.pos.x
    local y = ges.pos.y
    local W = self.dimen.w
    local H = self.dimen.h

    if y <= 36 and x <= math.floor(W * 0.33) then
        self:_close()
    elseif y >= H - 40 then
        if x <= math.floor(W * 0.33) then
            self:_page(-1)
        elseif x >= math.floor(W * 0.66) then
            self:_page(1)
        else
            self:_close()
        end
    else
        local idx = self:_wordAt(x, y)
        if idx then
            self:_selectWord(idx)
        end
    end
    return true
end

function ScrubPreview:onClose()
    self:_close()
    return true
end
ScrubPreview.onBack = ScrubPreview.onClose

-- ── Page navigation ──────────────────────────────────────────────────────────

function ScrubPreview:_page(direction)
    self.engine:seekTo(self.engine.current_idx + direction * PAGE_WORDS)
    UIManager:setDirty(self, "ui")
end

function ScrubPreview:_wordAt(x, y)
    for __, hit in ipairs(self._word_hits or {}) do
        if x >= hit.x and x <= hit.x + hit.w and y >= hit.y and y <= hit.y + hit.h then
            return hit.idx
        end
    end
end

function ScrubPreview:_selectWord(idx)
    self.engine:seekTo(idx)
    if self.on_select then
        if not self._closed then
            self._closed = true
            UIManager:close(self)
        end
        self.on_select(idx)
    else
        self:_close()
    end
end

-- ── Close ────────────────────────────────────────────────────────────────────

function ScrubPreview:_close()
    if self._closed then return end
    self._closed = true
    UIManager:close(self)
    if self.on_close then self.on_close() end
end

return ScrubPreview
