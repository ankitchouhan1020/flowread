--[[
ScrubPreview  (v2)
==================
Full-screen overlay opened when the user swipes left/right while paused in
RSVP mode. Shows ~9 lines of text centred on the current word so the reader
can quickly browse forward/backward before returning to RSVP playback.

Gesture map:
  hold               → enter continuous-scroll mode
  pan (while held)   → update finger Y, adjusting scroll direction + speed
  hold_release       → stop scrolling (preview stays open at new position)
  tap                → close preview; RSVP resumes at the current position
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
-- screen, while cutting the scan window from 500 to 160 words per scroll tick.
local CONTEXT_WORDS = 80
local ANCHOR_FRAC  = 0.42
local LINE_GAP     = 1.65
-- Dead-zone near screen centre (fraction of half-height) where scroll stops
local DEAD_ZONE    = 0.12
-- Maximum words-per-step at the screen edge
local MAX_STEP     = 10

-- Re-use typography helpers from RSVPScreen and the shared layout cache.
local RSVPScreen = require("modules/ui/rsvp_screen")
local TextLayout  = require("modules/engine/text_layout")

local ScrubPreview = InputContainer:extend{
    name = "scrub_preview",
}

-- ── Lifecycle ────────────────────────────────────────────────────────────────

function ScrubPreview:init()
    -- self.engine, self.settings, self.on_close already set by new{...}

    self._scrolling = false
    self._scroll_y  = Screen:getHeight() / 2
    -- Stable closure reference for UIManager:unschedule
    self._scrollFn  = function() self:_scrollLoop() end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    self:_initColors()

    self.ges_events = {
        Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen }
        },
        Hold = {
            GestureRange:new{ ges = "hold", range = self.dimen }
        },
        HoldRelease = {
            GestureRange:new{ ges = "hold_release", range = self.dimen }
        },
        Pan = {
            GestureRange:new{ ges = "pan", range = self.dimen }
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
    local space_w  = RenderText:sizeUtf8Text(0, 9999, face, " ", false, false).x

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

    -- Header bar: "Browse  word X / total" hint
    local STATUS_H = 28
    local info  = self.engine:currentWordInfo()
    local ch, _ = self.engine:currentChapter()
    local hint  = ch and ch.title or _("Scrub Preview")
    local pos_str = info and string.format("%d / %d", info.index, info.total) or ""

    local hface = self._preview_hface
    RenderText:renderUtf8Text(bb, 8, STATUS_H - 5, hface, hint,
        false, false, self.dim_color)
    local ps_w = RenderText:sizeUtf8Text(0, W, hface, pos_str, false, false).x
    RenderText:renderUtf8Text(bb, W - ps_w - 8, STATUS_H - 5, hface, pos_str,
        false, false, self.dim_color)
    bb:paintRect(0, STATUS_H, W, 1, self.dim_color)

    -- Scroll hint footer
    local FOOTER_H = 24
    local ftip = _("Tap to return  |  Hold + drag to browse")
    local ftip_w = RenderText:sizeUtf8Text(0, W, hface, ftip, false, false).x
    bb:paintRect(0, H - FOOTER_H - 1, W, 1, self.dim_color)
    RenderText:renderUtf8Text(bb, math.floor((W - ftip_w) / 2),
        H - 6, hface, ftip, false, false, self.dim_color)

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
            for _, wd in ipairs(line.words) do
                local is_cur = (wd.idx == current)

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

function ScrubPreview:onTap(ges)
    self:_close()
    return true
end

function ScrubPreview:onHold(ges)
    self._scroll_y  = ges.pos.y
    self._scrolling = true
    UIManager:scheduleIn(0.05, self._scrollFn)
    return true
end

function ScrubPreview:onPan(ges)
    -- Update the reference y so _scrollLoop picks up the new position
    if ges.pos then
        self._scroll_y = ges.pos.y
    end
    return true
end

function ScrubPreview:onHoldRelease(ges)
    self._scrolling = false
    UIManager:unschedule(self._scrollFn)
    return true
end

function ScrubPreview:onClose()
    self:_close()
    return true
end
ScrubPreview.onBack = ScrubPreview.onClose

-- ── Continuous scroll loop ───────────────────────────────────────────────────

function ScrubPreview:_scrollLoop()
    if not self._scrolling then return end

    local H         = self.dimen.h
    local center_y  = H / 2
    local dy        = self._scroll_y - center_y
    local half_h    = H / 2
    -- Normalised distance from centre: 0 (centre) → 1 (edge)
    local norm      = math.abs(dy) / half_h

    if norm < DEAD_ZONE then
        -- Inside dead zone: don't scroll, wait
        UIManager:scheduleIn(0.2, self._scrollFn)
        return
    end

    -- Map norm (DEAD_ZONE..1) → step (1..MAX_STEP)
    local adjusted = (norm - DEAD_ZONE) / (1 - DEAD_ZONE)
    local step     = math.max(1, math.floor(adjusted * MAX_STEP))

    if dy < 0 then
        self.engine:seekTo(self.engine.current_idx - step)
    else
        self.engine:seekTo(self.engine.current_idx + step)
    end

    UIManager:setDirty(self, function()
        return "partial", self.dimen
    end)

    -- Faster delay when farther from centre
    local delay = math.max(0.05, 0.35 - adjusted * 0.30)
    UIManager:scheduleIn(delay, self._scrollFn)
end

-- ── Close ────────────────────────────────────────────────────────────────────

function ScrubPreview:_close()
    self._scrolling = false
    UIManager:unschedule(self._scrollFn)
    UIManager:close(self)
    if self.on_close then self.on_close() end
end

return ScrubPreview
