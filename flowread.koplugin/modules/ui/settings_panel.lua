local Blitbuffer      = require("ffi/blitbuffer")
local ConfirmBox      = require("ui/widget/confirmbox")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InfoMessage     = require("ui/widget/infomessage")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local _               = require("gettext")

local Screen = Device.screen

local PAD        = Screen:scaleBySize(12)
local ROW_H      = Screen:scaleBySize(72)
local LABEL_FACE = Font:getFace("cfont", 18)
local VALUE_FACE = Font:getFace("smallinfofontbold", 17)

-- ─────────────────────────────────────────────────────────────────────────────
-- Row builder: label (60%) | value + chevron (40%)
-- ─────────────────────────────────────────────────────────────────────────────
local function makeRow(screen_w, label, value_text, on_tap)
    local dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = ROW_H }
    local row   = InputContainer:new{ dimen = dimen }
    row.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = dimen } },
    }
    row.onTap = function()
        on_tap()
        return true
    end

    local inner_w = screen_w - PAD * 2
    local label_w = math.floor(inner_w * 0.62)
    local value_w = inner_w - label_w - PAD

    row[1] = FrameContainer:new{
        width      = screen_w,
        height     = ROW_H,
        padding    = PAD,
        margin     = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            TextBoxWidget:new{
                text          = label,
                face          = LABEL_FACE,
                width         = label_w,
                height        = ROW_H - PAD * 2,
                height_adjust = true,
                alignment     = "left",
            },
            HorizontalSpan:new{ width = PAD },
            FrameContainer:new{
                width      = value_w,
                height     = ROW_H - PAD * 2,
                padding    = 0,
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                TextBoxWidget:new{
                    text          = value_text .. "  ›",
                    face          = VALUE_FACE,
                    width         = value_w,
                    height        = ROW_H - PAD * 2,
                    height_adjust = true,
                    alignment     = "right",
                },
            },
        },
    }
    return row
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SettingsPanel: fullscreen settings overlay
-- ─────────────────────────────────────────────────────────────────────────────
local SettingsPanel = InputContainer:extend{
    name     = "flowread_settings",
    on_close = nil,
}

function SettingsPanel:init()
    self.key_events = {
        Close = { { "Back" }, doc = "close FlowRead settings" },
    }
    self:_buildUI()
end

function SettingsPanel:_buildUI()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local s = self.settings

    local title_bar = TitleBar:new{
        width            = screen_w,
        title            = _("FlowRead Settings"),
        with_bottom_line = true,
        close_callback   = function() self:onClose() end,
        show_parent      = self,
    }
    local title_h = title_bar:getSize().h

    local rows = VerticalGroup:new{ align = "left" }

    local function addRow(label, value_text, on_tap)
        table.insert(rows, makeRow(screen_w, label, value_text, on_tap))
        table.insert(rows, LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen      = Geom:new{ w = screen_w, h = Size.line.thin },
        })
    end

    local function refresh() self:_buildUI(); UIManager:setDirty(self, "ui") end

    local function cycle(key, options)
        local cur = s:get(key)
        local idx = 1
        for i, v in ipairs(options) do if v == cur then idx = i; break end end
        s:set(key, options[(idx % #options) + 1])
        refresh()
    end

    local function boolLabel(v) return v and _("On") or _("Off") end

    -- WPM
    addRow(_("Words per minute"), tostring(s:get("wpm")), function()
        local SpinWidget = require("ui/widget/spinwidget")
        UIManager:show(SpinWidget:new{
            title_text        = _("Words per minute"),
            value             = s:get("wpm"),
            value_min         = 60,
            value_max         = 800,
            value_step        = 10,
            ok_always_enabled = true,
            callback          = function(spin)
                s:set("wpm", spin.value)
                refresh()
            end,
        })
    end)

    -- Reading mode
    addRow(_("Reading mode"), s:get("reading_mode"), function()
        cycle("reading_mode", {"rsvp", "scroll"})
    end)

    -- Font size
    addRow(_("Font size"), s:get("font_size"), function()
        cycle("font_size", {"small", "medium", "large"})
    end)

    -- Typeface
    addRow(_("Typeface"), s:get("typeface"), function()
        cycle("typeface", {"default", "atkinson", "opendyslexic"})
    end)

    -- Theme
    addRow(_("Theme"), s:get("theme"), function()
        cycle("theme", {"light", "dark"})
    end)

    -- Anchor position
    addRow(_("Anchor position"), tostring(s:get("anchor_position")) .. "%", function()
        local SpinWidget = require("ui/widget/spinwidget")
        UIManager:show(SpinWidget:new{
            title_text        = _("Anchor position (% from left)"),
            value             = s:get("anchor_position"),
            value_min         = 20,
            value_max         = 80,
            value_step        = 5,
            ok_always_enabled = true,
            callback          = function(spin)
                s:set("anchor_position", spin.value)
                refresh()
            end,
        })
    end)

    -- Anchor style
    addRow(_("Anchor style"), s:get("anchor_style"), function()
        cycle("anchor_style", {"invert", "bold", "underline", "none"})
    end)

    -- Anchor guide lines
    addRow(_("Anchor guide lines"), boolLabel(s:get("anchor_guides")), function()
        s:set("anchor_guides", not s:get("anchor_guides"))
        refresh()
    end)

    -- Phantom words
    addRow(_("Phantom words (context)"), boolLabel(s:get("phantom_words")), function()
        s:set("phantom_words", not s:get("phantom_words"))
        refresh()
    end)

    -- Letter spacing
    addRow(_("Letter spacing"), tostring(s:get("letter_spacing")) .. "px", function()
        local SpinWidget = require("ui/widget/spinwidget")
        UIManager:show(SpinWidget:new{
            title_text        = _("Letter spacing (px between chars)"),
            value             = s:get("letter_spacing"),
            value_min         = -4,
            value_max         = 12,
            value_step        = 2,
            ok_always_enabled = true,
            callback          = function(spin)
                s:set("letter_spacing", spin.value)
                refresh()
            end,
        })
    end)

    -- Pacing: long words
    addRow(_("Pacing: long words"), boolLabel(s:get("pacing_long_words")), function()
        s:set("pacing_long_words", not s:get("pacing_long_words"))
        refresh()
    end)

    -- Pacing: complexity
    addRow(_("Pacing: complex words"), boolLabel(s:get("pacing_complexity")), function()
        s:set("pacing_complexity", not s:get("pacing_complexity"))
        refresh()
    end)

    -- Pacing: punctuation
    addRow(_("Pacing: punctuation pauses"), boolLabel(s:get("pacing_punctuation")), function()
        s:set("pacing_punctuation", not s:get("pacing_punctuation"))
        refresh()
    end)

    -- Books folder
    addRow(_("Books folder"), s:get("books_path"), function()
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new{
            title      = _("Books folder path"),
            input      = s:get("books_path"),
            input_type = "string",
            buttons    = {{
                {
                    text     = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text             = _("Save"),
                    is_enter_default = true,
                    callback         = function()
                        local path = dialog:getInputText()
                        if path and path ~= "" then
                            s:set("books_path", path)
                        end
                        UIManager:close(dialog)
                        refresh()
                    end,
                },
            }},
        }
        UIManager:show(dialog)
    end)

    -- Reset all
    addRow(_("Reset all to defaults"), "", function()
        UIManager:show(ConfirmBox:new{
            text        = _("Reset all FlowRead settings to defaults?"),
            ok_text     = _("Reset"),
            ok_callback = function()
                s:reset()
                refresh()
                UIManager:show(InfoMessage:new{ text = _("Settings reset."), timeout = 2 })
            end,
        })
    end)

    -- Wrap rows in scrollable area
    local list_h = screen_h - title_h
    local ok_sc, ScrollableContainer = pcall(require, "ui/widget/container/scrollablecontainer")
    local content
    if ok_sc then
        content = ScrollableContainer:new{
            dimen       = Geom:new{ x = 0, y = 0, w = screen_w, h = list_h },
            show_parent = self,
            rows,
        }
    else
        content = FrameContainer:new{
            width      = screen_w,
            height     = list_h,
            padding    = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            rows,
        }
    end

    self[1] = FrameContainer:new{
        width      = screen_w,
        height     = screen_h,
        padding    = 0,
        margin     = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            title_bar,
            content,
        },
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
end

function SettingsPanel:onClose()
    if self._closed then return true end
    self._closed = true
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

return SettingsPanel
