--[[
RSVPScreen
==========
Full-screen InputContainer that renders the RSVP word display.

Rendering is done via paintTo → RenderText so every word advance
can issue a "partial" dirty rect, keeping e-ink ghosting minimal.

Layout (portrait or landscape):
  ┌──────────────────────────────────────────┐
  │  [WPM: 250]            [Book title]      │  ← 28px status bar
  │                                          │
  │                                          │
  │   [prev]   p r [E] s s u r e   [next]   │  ← word centred on ORP
  │                  ↑ anchor                │
  │                                          │
  │  ████████████████░░░░░░░░░░░  34% · 8m  │  ← 22px progress bar
  └──────────────────────────────────────────┘

Gesture map
  Tap              → toggle play / pause
  Double-tap       → lock autoplay (same as "play, don't stop on sentence")
  Tap left 10%     → rewind to start of sentence
  Swipe north      → WPM +10
  Swipe south      → WPM −10
  Swipe east       → scrub forward
  Swipe west       → scrub backward
  Long-press       → open settings panel
  Hardware back    → save position & close
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
local STATUS_H   = 28
local PROGRESS_H = 22
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
    self:_startPlayback()
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
        local area_h = H - STATUS_H - 1 - PROGRESS_H - BOTTOM_PAD - 1
        self:_paintWord(bb, W, area_y_top, area_h, word_info)
    end

    -- Horizontal rule above progress bar
    local prog_y = H - PROGRESS_H - BOTTOM_PAD
    bb:paintRect(0, prog_y - 1, W, 1, self.dim_color)

    -- Progress bar
    self:_paintProgress(bb, W, prog_y, word_info)
end

function RSVPScreen:_paintStatus(bb, W)
    local face = self._rc.ui_face
    local state_str = self.is_locked and ">>" or (self.is_playing and ">" or "||")
    local label = state_str .. "  " .. self.engine.wpm .. " WPM"

    RenderText:renderUtf8Text(bb, 8, STATUS_H - 5, face, label,
        true, false, self.dim_color)

    -- Right side: current chapter title if available, else file name
    local right_label
    local ch = self.engine:currentChapter()
    if ch then
        right_label = ch.title
    else
        right_label = self.file_path:match("[^/]+$") or ""
    end
    if #right_label > 32 then right_label = right_label:sub(1, 29) .. "..." end
    local rl_w = RenderText:sizeUtf8Text(0, W, face, right_label, true, false).x
    RenderText:renderUtf8Text(bb, W - rl_w - 8, STATUS_H - 5, face, right_label,
        true, false, self.dim_color)
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

    -- Anchor X: left edge of ORP letter sits at anchor_position% of screen
    local anchor_x = math.floor(W * rc.anchor_ratio) - math.floor(orp_w / 2)
    anchor_x = math.max(4, math.min(W - total_w - 4, anchor_x - prefix_w) + prefix_w)

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
        bb:paintRect(cx - 1, baseline_y - font_pt - guide_gap - guide_h,
                     2, guide_h, self.dim_color)
        bb:paintRect(cx - 1, baseline_y + guide_gap,
                     2, guide_h, self.dim_color)
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

    -- Bar geometry: leave room for the text label on the right
    local label = string.format("%d%%  %dm", math.floor(frac * 100),
                                math.ceil(self.engine:minutesRemaining()))
    local label_w = RenderText:sizeUtf8Text(0, W, face, label, true, false).x
    local bar_w   = W - label_w - 20
    local bar_h   = PROGRESS_H - 6
    local bar_x   = 8

    -- Track
    bb:paintRect(bar_x, bar_y + 3, bar_w, bar_h, self.dim_color)
    -- Fill
    local fill_w = math.floor(bar_w * frac)
    if fill_w > 0 then
        bb:paintRect(bar_x, bar_y + 3, fill_w, bar_h, self.fg_color)
    end

    -- Label
    local label_x = W - label_w - 8
    local text_y  = bar_y + PROGRESS_H - 4
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
        self.phantom_color = Blitbuffer.COLOR_GREY
        self.orp_bg        = Blitbuffer.COLOR_WHITE
        self.orp_fg        = Blitbuffer.COLOR_BLACK
        self.accent_color  = Blitbuffer.COLOR_WHITE
    else
        -- light (default)
        self.bg_color      = Blitbuffer.COLOR_WHITE
        self.fg_color      = Blitbuffer.COLOR_BLACK
        self.dim_color     = Blitbuffer.COLOR_GREY
        self.phantom_color = Blitbuffer.COLOR_GREY
        self.orp_bg        = Blitbuffer.COLOR_BLACK
        self.orp_fg        = Blitbuffer.COLOR_WHITE
        self.accent_color  = Blitbuffer.COLOR_BLACK
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
        self:_setDirty("partial")
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

    self:_setDirty("partial")

    -- Pause at sentence end if requested
    local info = self.engine:currentWordInfo()
    if self._pause_at_sentence and info and info.is_sentence_end then
        self.is_playing = false
        self.is_locked  = false
        self._pause_at_sentence = false
        self:_setDirty("partial")
        return
    end

    self:_scheduleNext()
end

function RSVPScreen:_setDirty(mode)
    UIManager:setDirty(self, mode or "partial")
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
    -- Left-edge 10% → sentence rewind
    if ges.pos.x < self.dimen.w * 0.10 then
        self.engine:rewindSentence()
        if self.is_playing then
            -- Restart playback from rewound position
            self:_stopPlayback()
            self:_startPlayback()
        end
        self:_setDirty("partial")
        return true
    end

    -- Normal tap: toggle play / pause
    if self.is_playing then
        -- Pause at end of current sentence (like rsvpnano release-to-pause)
        self:_pauseAtSentenceEnd()
    else
        self:_startPlayback()
    end
    self:_setDirty("partial")
    return true
end

function RSVPScreen:onDoubleTap(_, ges)
    if self.is_locked then
        -- Unlock: stop at sentence end
        self:_pauseAtSentenceEnd()
        self.is_locked = false
    else
        -- Lock autoplay: play continuously without pausing on sentences
        self.is_locked = true
        self._pause_at_sentence = false
        if not self.is_playing then
            self:_startPlayback()
        end
    end
    self:_setDirty("partial")
    return true
end

function RSVPScreen:onSwipe(_, ges)
    if not ges then return true end
    local dir = ges.direction
    if dir == "north" then
        self.engine:increaseWPM(10)
        self:_setDirty("partial")
    elseif dir == "south" then
        self.engine:decreaseWPM(10)
        self:_setDirty("partial")
    elseif dir == "east" or dir == "west" then
        if not self.is_playing then
            -- Paused: open the hold-and-browse scrub preview
            local ScrubPreview = require("modules/ui/scrub_preview")
            UIManager:show(ScrubPreview:new{
                engine   = self.engine,
                settings = self.settings,
                on_close = function() self:_setDirty("full") end,
            })
        else
            -- Playing: immediate word-jump (no preview disruption)
            if dir == "east" then self.engine:scrubForward()
            else self.engine:scrubBackward() end
            self:_setDirty("partial")
        end
    end
    return true
end

function RSVPScreen:onHoldRelease(_, ges)
    if self.is_playing then self:_stopPlayback() end

    local has_chapters = self.engine:chapterCount() > 0
    local self_ref = self

    local function openSettings()
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

    if not has_chapters then
        -- No chapters: go straight to settings
        openSettings()
        return true
    end

    -- Has chapters: show a two-button choice
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    local dialog
    dialog = ButtonDialogTitle:new{
        title   = _("Menu"),
        buttons = {
            {
                {
                    text     = _("Chapters"),
                    callback = function()
                        UIManager:close(dialog)
                        local ChaptersScreen = require("modules/ui/chapters_screen")
                        UIManager:show(ChaptersScreen:new{
                            engine    = self_ref.engine,
                            on_return = function()
                                self_ref:_setDirty("full")
                            end,
                        })
                    end,
                },
                {
                    text     = _("Settings"),
                    callback = function()
                        UIManager:close(dialog)
                        openSettings()
                    end,
                },
            },
            {
                {
                    text     = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return true
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
