--[[
RSVPScreen
==========
Full-screen InputContainer that renders the RSVP word display.

Rendering is done via paintTo → RenderText so every word advance
can issue a "partial" dirty rect, keeping e-ink ghosting minimal.

Layout (portrait or landscape):
  ┌──────────────────────────────────────────┐
  │  Settings   Play / WPM      Exit          │  ← header (tap left / right)
  │  (book title)                             │
  │   [phantom]  w o r d  [phantom]          │  ← ORP at fixed pivot (anchor %); tap: play/pause
  │  Slower   Browse   Faster                │  ← tap row (no hardware keys)
  │  ████████████░░░░░░░░░░░  34% · 8m       │  ← progress
  └──────────────────────────────────────────┘

Gesture map
  Tap (main area)  → play / pause
  Tap header left  → settings
  Tap header right → exit
  Tap bottom row   → slower WPM | browse words | faster WPM (touch-only friendly)
  Double-tap       → exit
  Swipe north/south → WPM ±10 (optional; same as bottom row)
  Swipe east/west  → when playing: jump words; when paused: open browse (optional)
  Long-press       → settings
  Hardware back    → save position & close (if device has keys)
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
local logger         = require("logger")
local _              = require("gettext")

-- Typeface name → KOReader font name map (with graceful fallback)
local TYPEFACE_MAP = {
    default      = "cfont",
    atkinson     = "Atkinson Hyperlegible",
    opendyslexic = "OpenDyslexic",
}

-- Iterate UTF-8 characters as individual byte-strings
local function utf8_chars(s)
    local i = 1
    return function()
        if i > #s then return nil end
        local b = s:byte(i)
        local len = (b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
        local ch = s:sub(i, i + len - 1)
        i = i + len
        return ch
    end
end

-- How often (in words) we autosave reading position
local AUTOSAVE_EVERY = 15

-- Status-bar and progress-bar heights in pixels
local STATUS_H   = 44
local PROGRESS_H = 22
--- Bottom strip: WPM / browse (tap targets for devices with no hardware keys)
local BOTTOM_CONTROLS_H = math.max(32, Screen:scaleBySize(36))
-- Gap between the progress bar and the screen bottom
local BOTTOM_PAD = 4

-- Gap in pixels between the phantom word and the main word
local PHANTOM_GAP = 32

local RSVPScreen = InputContainer:extend{
    name = "rsvp_screen",
}

-- ── Lifecycle ──────────────────────────────────────────────────────────────

function RSVPScreen:init()
    self.file_path = self.file_path or ""

    self.is_playing  = false
    self.is_locked   = false   -- double-tap lock mode
    self._word_since_save = 0

    -- Full-screen dimensions
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    -- Set up colours and render/session cache
    self:_initColors()

    -- Single stable advance closure; UIManager:unschedule is reliable across
    -- all calls because the function reference never changes between advances.
    self._advanceFn = function()
        local ok, err = pcall(function() self:_onWordTimer() end)
        if not ok then self:_handleRuntimeError(err) end
    end

    -- Set up gesture handlers
    self.ges_events = {
        Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen }
        },
        DoubleTap = {
            GestureRange:new{ ges = "double_tap", range = self.dimen }
        },
        Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen }
        },
        HoldRelease = {
            GestureRange:new{ ges = "hold_release", range = self.dimen }
        },
    }

    -- Hardware back key
    if Device:hasKeys() then
        self.key_events = {
            Close = { { "Back" }, doc = "close RSVP reader" },
        }
    end
end

function RSVPScreen:onShow()
    UIManager:setDirty(self, "full")
end

-- ── Rendering ──────────────────────────────────────────────────────────────

function RSVPScreen:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y

    local W = self.dimen.w
    local H = self.dimen.h

    -- Background
    bb:fill(self.bg_color)

    -- Status bar
    self:_paintStatus(bb, W)

    -- Horizontal rule below status bar
    bb:paintRect(0, STATUS_H, W, 1, self.dim_color)

    -- Word display (main area between status bar and progress bar)
    local word_info = self.engine:currentWordInfo()
    if word_info then
        local area_y_top = STATUS_H + 1
        local area_h = H - STATUS_H - 1 - BOTTOM_CONTROLS_H - PROGRESS_H - BOTTOM_PAD - 1
        self:_paintWord(bb, W, area_y_top, area_h, word_info)
    end

    local controls_top = H - BOTTOM_PAD - PROGRESS_H - BOTTOM_CONTROLS_H
    local prog_y       = H - BOTTOM_PAD - PROGRESS_H
    bb:paintRect(0, controls_top - 1, W, 1, self.dim_color)
    self:_paintBottomControls(bb, W, controls_top)
    bb:paintRect(0, prog_y - 1, W, 1, self.dim_color)

    -- Progress bar
    self:_paintProgress(bb, W, prog_y, word_info)
end

function RSVPScreen:_paintBottomControls(bb, W, controls_top)
    local face = self._rc.prog_face
    local labels = { _("Slower"), _("Browse"), _("Faster") }
    local y_mid = controls_top + math.floor(BOTTOM_CONTROLS_H * 0.62)
    local col_w = math.floor(W / 3)
    for i, label in ipairs(labels) do
        local lw = RenderText:sizeUtf8Text(0, W, face, label, true, false).x
        local cx = (i - 1) * col_w + math.floor(col_w / 2) - math.floor(lw / 2)
        RenderText:renderUtf8Text(bb, cx, y_mid, face, label, true, false, self.accent_color)
    end
end

function RSVPScreen:_paintStatus(bb, W)
    local face = self._rc.ui_face
    local left_label = _("Settings")
    local right_label = _("Exit")
    local state_label = (self.is_playing and ">  " or "||  ") .. self.engine.wpm .. " WPM"

    RenderText:renderUtf8Text(bb, 8, 20, face, left_label, true, false, self.fg_color)

    local state_w = RenderText:sizeUtf8Text(0, W, face, state_label, true, false).x
    RenderText:renderUtf8Text(bb, math.floor((W - state_w) / 2), 20, face, state_label,
        true, false, self.fg_color)

    local right_w = RenderText:sizeUtf8Text(0, W, face, right_label, true, false).x
    RenderText:renderUtf8Text(bb, W - right_w - 8, 20, face, right_label,
        true, false, self.fg_color)

    local book_label
    local ch = self.engine:currentChapter()
    if ch then
        book_label = ch.title
    else
        book_label = self.file_path:match("[^/]+$") or ""
    end
    if #book_label > 42 then book_label = book_label:sub(1, 39) .. "..." end
    local book_w = RenderText:sizeUtf8Text(0, W, face, book_label, true, false).x
    RenderText:renderUtf8Text(bb, math.floor((W - book_w) / 2), STATUS_H - 5,
        face, book_label, true, false, self.dim_color)
end

function RSVPScreen:_paintWord(bb, W, area_y, area_h, word_info)
    local rc       = self._rc
    local font_pt  = rc.font_pt
    local face     = rc.face
    local tracking = rc.tracking

    local word   = word_info.text
    local orp_i  = word_info.orp_idx   -- 1-based byte index

    local prefix = word:sub(1, orp_i - 1)
    local orp_ch = word:sub(orp_i, orp_i)
    local suffix = word:sub(orp_i + 1)

    local prefix_w = self:_trackedTextWidth(face, prefix, tracking)
    local orp_w    = self:_trackedTextWidth(face, orp_ch, tracking)
    local suffix_w = self:_trackedTextWidth(face, suffix, tracking)
    local total_w  = prefix_w + orp_w + suffix_w

    -- RSVP fixation: ORP letter center stays at a fixed horizontal pivot
    -- (Settings → Anchor position). Layout clamps only at screen edges.
    local MARGIN    = 8
    local pivot_x   = math.floor(W * rc.anchor_ratio)
    local orp_cw2   = math.floor(orp_w / 2)
    local word_left = pivot_x - prefix_w - orp_cw2
    local max_left  = W - MARGIN - total_w
    local min_left  = MARGIN
    if max_left < min_left then
        -- Word wider than usable width: keep pivot best-effort.
        word_left = math.max(max_left, math.min(min_left, word_left))
    else
        word_left = math.max(min_left, math.min(max_left, word_left))
    end
    local anchor_x = word_left + prefix_w

    local baseline_y = area_y + math.floor(area_h / 2) + math.floor(font_pt * 0.3)
    local style = rc.style

    -- ── ORP background (invert style) ──────────────────────────────────────
    if style == "invert" then
        local pad_x, pad_y = 3, 4
        bb:paintRect(
            anchor_x - pad_x,
            baseline_y - font_pt - pad_y,
            orp_w + pad_x * 2,
            font_pt + pad_y * 2 + 2,
            self.orp_bg
        )
    end

    -- ── Anchor guide lines ─────────────────────────────────────────────────
    if rc.anchor_guides then
        local guide_h   = math.floor(font_pt * 0.35)
        local guide_gap = 6
        local cx = anchor_x + math.floor(orp_w / 2)
        local gcolor = self.anchor_guide_color or self.dim_color
        bb:paintRect(cx - 1, baseline_y - font_pt - guide_gap - guide_h,
                     2, guide_h, gcolor)
        bb:paintRect(cx - 1, baseline_y + guide_gap,
                     2, guide_h, gcolor)
    end

    -- ── Underline style ────────────────────────────────────────────────────
    if style == "underline" then
        bb:paintRect(anchor_x, baseline_y + 3, orp_w, 3, self.accent_color)
    end

    -- ── Prefix, ORP letter, suffix ─────────────────────────────────────────
    -- Widths are pre-measured above; _renderTrackedText return value is unused.
    if prefix ~= "" then
        self:_renderTrackedText(bb, anchor_x - prefix_w, baseline_y,
            face, prefix, false, self.fg_color, tracking)
    end

    local orp_fg   = (style == "invert") and self.orp_fg or self.fg_color
    local orp_bold = (style == "bold")
    self:_renderTrackedText(bb, anchor_x, baseline_y,
        face, orp_ch, orp_bold, orp_fg, tracking)

    if suffix ~= "" then
        self:_renderTrackedText(bb, anchor_x + orp_w, baseline_y,
            face, suffix, false, self.fg_color, tracking)
    end

    -- ── Phantom words ──────────────────────────────────────────────────────
    if rc.phantom_words then
        local pface = rc.phantom_face

        if word_info.prev_word then
            local pw = self:_trackedTextWidth(pface, word_info.prev_word, tracking)
            local px = anchor_x - prefix_w - PHANTOM_GAP - pw
            if px >= 0 then
                self:_renderTrackedText(bb, px, baseline_y,
                    pface, word_info.prev_word, false, self.phantom_color, tracking)
            end
        end

        if word_info.next_word then
            local nx = anchor_x + orp_w + suffix_w + PHANTOM_GAP
            if nx + self:_trackedTextWidth(pface, word_info.next_word, tracking) <= W then
                self:_renderTrackedText(bb, nx, baseline_y,
                    pface, word_info.next_word, false, self.phantom_color, tracking)
            end
        end
    end
end

function RSVPScreen:_paintProgress(bb, W, bar_y, word_info)
    local face = self._rc.prog_face

    -- Progress fraction
    local frac = self.engine:progress()

    -- Bar geometry: leave room for the progress label on the right
    local label = string.format("%d%%  %dm", math.floor(frac * 100),
                                math.ceil(self.engine:minutesRemaining()))
    local label_w = RenderText:sizeUtf8Text(0, W, face, label, true, false).x
    local bar_w   = W - label_w - 20
    local bar_h   = 5
    local bar_x   = 8

    -- Track
    bb:paintRect(bar_x, bar_y + 2, bar_w, bar_h, self.dim_color)
    -- Fill
    local fill_w = math.floor(bar_w * frac)
    if fill_w > 0 then
        bb:paintRect(bar_x, bar_y + 2, fill_w, bar_h, self.fg_color)
    end

    -- Label
    local label_x = W - label_w - 8
    local text_y  = bar_y + 12
    RenderText:renderUtf8Text(bb, label_x, text_y, face, label,
        true, false, self.fg_color)

end

-- ── Typography helpers ─────────────────────────────────────────────────────

---Return a font face honouring the current typeface setting.
---Falls back to "cfont" if the requested face is not installed.
function RSVPScreen:_getFace(size)
    local name = TYPEFACE_MAP[self.settings:get("typeface")] or "cfont"
    if name ~= "cfont" then
        local ok, face = pcall(Font.getFace, Font, name, size)
        if ok and face then return face end
    end
    return Font:getFace("cfont", size)
end

---Measure the pixel width of `text` rendered with `face`, accounting for
---optional per-character `tracking` (letter-spacing) in pixels.
function RSVPScreen:_trackedTextWidth(face, text, tracking)
    if not text or text == "" then return 0 end
    tracking = tracking or 0
    if tracking == 0 then
        return RenderText:sizeUtf8Text(0, 9999, face, text, true, false).x
    end
    local total, count = 0, 0
    for ch in utf8_chars(text) do
        total = total + RenderText:sizeUtf8Text(0, 9999, face, ch, true, false).x
        count = count + 1
    end
    -- Add tracking between characters (not after the last one)
    return total + tracking * math.max(0, count - 1)
end

---Render `text` at (x, y) with optional per-character tracking.
---
---For tracking == 0: renders with a single RenderText call. The return value
---is `x` unchanged; callers that need the post-render x must advance it
---manually using widths pre-measured via _trackedTextWidth.
---
---For tracking ~= 0: advances x character-by-character and returns the final x.
function RSVPScreen:_renderTrackedText(bb, x, y, face, text, bold, color, tracking)
    if not text or text == "" then return x end
    tracking = tracking or 0
    if tracking == 0 then
        -- Single call, no extra sizeUtf8Text — callers use pre-measured widths.
        RenderText:renderUtf8Text(bb, x, y, face, text, true, bold, color)
        return x
    end
    local chars = {}
    for ch in utf8_chars(text) do table.insert(chars, ch) end
    for ci, ch in ipairs(chars) do
        RenderText:renderUtf8Text(bb, x, y, face, ch, true, bold, color)
        local w = RenderText:sizeUtf8Text(0, 9999, face, ch, true, bold).x
        x = x + w + (ci < #chars and tracking or 0)
    end
    return x
end

-- ── Colour theme ───────────────────────────────────────────────────────────

function RSVPScreen:_initColors()
    if self.settings:get("theme") == "dark" then
        self.bg_color      = Blitbuffer.COLOR_BLACK
        self.fg_color      = Blitbuffer.COLOR_WHITE
        self.dim_color     = Blitbuffer.COLOR_GREY
        -- Mid grey on black is invisible on e-ink; use a lighter grey for context words.
        self.phantom_color = Blitbuffer.COLOR_LIGHT_GRAY
        self.orp_bg        = Blitbuffer.COLOR_WHITE
        self.orp_fg        = Blitbuffer.COLOR_BLACK
        self.accent_color  = Blitbuffer.COLOR_WHITE
        -- Guides must stay visible on black (dim_title stays grey for secondary text).
        self.anchor_guide_color = Blitbuffer.COLOR_LIGHT_GRAY
    else
        -- light (default)
        self.bg_color      = Blitbuffer.COLOR_WHITE
        self.fg_color      = Blitbuffer.COLOR_BLACK
        self.dim_color     = Blitbuffer.COLOR_GREY
        self.phantom_color = Blitbuffer.COLOR_GREY
        self.orp_bg        = Blitbuffer.COLOR_BLACK
        self.orp_fg        = Blitbuffer.COLOR_WHITE
        self.accent_color  = Blitbuffer.COLOR_BLACK
        self.anchor_guide_color = Blitbuffer.COLOR_GREY
    end

    -- Render/session cache: session-stable values rebuilt only when settings
    -- change. Eliminates ~8 LuaSettings reads + 2–3 font pcall lookups per
    -- word advance. Subclasses extend _rc after calling RSVPScreen._initColors.
    local s = self.settings
    self._rc = {
        font_pt            = s:getFontSizePt(),
        phantom_pt         = s:getPhantomFontSizePt(),
        tracking           = s:get("letter_spacing") or 0,
        anchor_ratio       = s:get("anchor_position") / 100,
        style              = s:get("anchor_style"),
        anchor_guides      = s:get("anchor_guides"),
        phantom_words      = s:get("phantom_words"),
        pacing_long_words  = s:get("pacing_long_words"),
        pacing_complexity  = s:get("pacing_complexity"),
        pacing_punctuation = s:get("pacing_punctuation"),
        face               = self:_getFace(s:getFontSizePt()),
        phantom_face       = self:_getFace(s:getPhantomFontSizePt()),
        ui_face            = self:_getFace(16),
        prog_face          = self:_getFace(14),
    }
end

-- ── Playback control ───────────────────────────────────────────────────────

function RSVPScreen:_startPlayback()
    if self.is_playing then return end
    self.is_playing = true
    self:_scheduleNext()
end

function RSVPScreen:_stopPlayback()
    self.is_playing = false
    self.is_locked  = false
    UIManager:unschedule(self._advanceFn)
end

function RSVPScreen:_pauseAtSentenceEnd()
    -- Stop at end of current sentence; keep is_locked unchanged
    self._pause_at_sentence = true
end

---Schedule the next word using the stable _advanceFn closure.
function RSVPScreen:_scheduleNext()
    if not self.is_playing then return end
    UIManager:unschedule(self._advanceFn)
    UIManager:scheduleIn(self.engine:displayTime(), self._advanceFn)
end

function RSVPScreen:_handleRuntimeError(err)
    self.is_playing = false
    UIManager:unschedule(self._advanceFn)
    logger.err("FlowRead runtime error: " .. tostring(err))
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text    = "FlowRead error:\n" .. tostring(err),
        timeout = 6,
    })
end

---Invoked by _advanceFn on each timer tick. Advances the word, autosaves,
---triggers a partial repaint, and re-schedules (or stops at book/sentence end).
function RSVPScreen:_onWordTimer()
    if not self.is_playing then return end

    local advanced = self.engine:advance()
    if not advanced then
        -- End of book
        self:_stopPlayback()
        self:_setDirty("ui")
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text    = _("End of book."),
            timeout = 3,
        })
        return
    end

    -- Autosave position every AUTOSAVE_EVERY words; flush deferred WPM too
    self._word_since_save = (self._word_since_save or 0) + 1
    if self._word_since_save >= AUTOSAVE_EVERY then
        self:_savePosition()
        self._word_since_save = 0
    end

    self:_setDirty("fast", self:_wordRegion())

    -- Pause at sentence end if requested
    local info = self.engine:currentWordInfo()
    if self._pause_at_sentence and info and info.is_sentence_end then
        self.is_playing = false
        self.is_locked  = false
        self._pause_at_sentence = false
        self:_setDirty("ui")
        return
    end

    self:_scheduleNext()
end

function RSVPScreen:_wordRegion()
    local margin = math.floor(self.dimen.h * 0.18)
    local bottom_reserved = PROGRESS_H + BOTTOM_PAD + BOTTOM_CONTROLS_H
    return Geom:new{
        x = 0,
        y = STATUS_H + margin,
        w = self.dimen.w,
        h = math.max(80, self.dimen.h - STATUS_H - bottom_reserved - margin * 2),
    }
end

function RSVPScreen:_setDirty(mode, region)
    UIManager:setDirty(self, mode or "ui", region)
end

function RSVPScreen:_savePosition()
    local info = self.engine:currentWordInfo()
    if info then
        self.settings:savePosition(self.file_path, info.index, info.total)
    end
end

-- ── Gesture handlers ───────────────────────────────────────────────────────

function RSVPScreen:onTap(_, ges)
    if not ges or not ges.pos then return true end

    if ges.pos.y <= STATUS_H then
        if ges.pos.x <= math.floor(self.dimen.w * 0.34) then
            self:_openSettings()
            return true
        elseif ges.pos.x >= math.floor(self.dimen.w * 0.66) then
            self:onClose()
            return true
        end
        return true
    end

    local H = self.dimen.h
    local W = self.dimen.w
    local controls_top = H - BOTTOM_PAD - PROGRESS_H - BOTTOM_CONTROLS_H
    local prog_y = H - BOTTOM_PAD - PROGRESS_H
    if ges.pos.y >= controls_top and ges.pos.y < prog_y then
        if ges.pos.x <= math.floor(W * 0.34) then
            self.engine:decreaseWPM(10)
            self:_setDirty("ui")
        elseif ges.pos.x >= math.floor(W * 0.66) then
            self.engine:increaseWPM(10)
            self:_setDirty("ui")
        else
            self:_openScrubPreview()
        end
        return true
    end

    -- Kindle-first behavior: tap anywhere immediately toggles playback.
    if self.is_playing then
        self:_stopPlayback()
    else
        self:_startPlayback()
    end
    self:_setDirty("ui")
    return true
end

function RSVPScreen:onDoubleTap(_, ges)
    self:onClose()
    return true
end

function RSVPScreen:onSwipe(_, ges)
    if not ges then return true end
    local dir = ges.direction
    if dir == "north" then
        self.engine:increaseWPM(10)
        self:_setDirty("ui")
    elseif dir == "south" then
        self.engine:decreaseWPM(10)
        self:_setDirty("ui")
    elseif dir == "east" or dir == "west" then
        if not self.is_playing then
            self:_openScrubPreview()
        else
            -- Playing: immediate word-jump (no preview disruption)
            if dir == "east" then self.engine:scrubForward()
            else self.engine:scrubBackward() end
            self:_setDirty("fast", self:_wordRegion())
        end
    end
    return true
end

function RSVPScreen:onHoldRelease(_, ges)
    self:_openSettings()
    return true
end

function RSVPScreen:_openSettings()
    if self.is_playing then self:_stopPlayback() end
    local self_ref = self
    local SettingsPanel = require("modules/ui/settings_panel")
    UIManager:show(SettingsPanel:new{
        settings = self_ref.settings,
        on_close = function()
            self_ref:_initColors()
            self_ref.engine:refreshSettingsCache(self_ref._rc)
            self_ref:_setDirty("full")
        end,
    })
end

function RSVPScreen:_openScrubPreview()
    if self.is_playing then self:_stopPlayback() end
    local self_ref = self
    local ScrubPreview = require("modules/ui/scrub_preview")
    local StartReadingMenu = require("modules/ui/start_reading_menu")
    local scrub
    scrub = ScrubPreview:new{
        engine   = self_ref.engine,
        settings = self_ref.settings,
        file_path = self_ref.file_path,
        on_overview_tap = function()
            scrub:_close()
            StartReadingMenu.show{
                settings = self_ref.settings,
                engine = self_ref.engine,
                file_path = self_ref.file_path,
                on_reading_ready = function()
                    self_ref:_initColors()
                    self_ref.engine:refreshSettingsCache(self_ref._rc)
                    self_ref:_setDirty("full")
                end,
            }
        end,
        on_close = function()
            self_ref:_setDirty("full")
        end,
    }
    UIManager:show(scrub)
end

-- Hardware back key
function RSVPScreen:onClose()
    if self._closed then return true end
    self._closed = true
    self:_stopPlayback()
    self:_savePosition()
    UIManager:close(self)
    return true
end

-- Also trap the Back key event name KOReader typically uses
RSVPScreen.onBack = RSVPScreen.onClose

return RSVPScreen
