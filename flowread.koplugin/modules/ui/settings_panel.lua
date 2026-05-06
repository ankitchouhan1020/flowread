local ConfirmBox  = require("ui/widget/confirmbox")
local Device      = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Menu        = require("ui/widget/menu")
local UIManager   = require("ui/uimanager")
local _           = require("gettext")

local Screen = Device.screen

local SettingsPanel = Menu:extend{
    name = "flowread_settings",
    is_borderless = true,
}

local function boolLabel(v)
    return v and _("On") or _("Off")
end

function SettingsPanel:init()
    self.title = _("FlowRead Settings")
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.item_table = self:_buildItems()
    Menu.init(self)
end

function SettingsPanel:_refresh()
    self:switchItemTable(nil, self:_buildItems())
    UIManager:setDirty(self, "ui")
end

function SettingsPanel:_cycle(key, options)
    local cur = self.settings:get(key)
    local idx = 1
    for i, v in ipairs(options) do
        if v == cur then idx = i; break end
    end
    self.settings:set(key, options[(idx % #options) + 1])
    self:_refresh()
end

function SettingsPanel:_buildItems()
    local s = self.settings
    local items = {}

    table.insert(items, {
        text = _("Controls"),
        mandatory = _("Help"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Start:\nTap a chapter to browse from there\nTap any preview word to start there\n\nReader:\nTap main area: play/pause\nHeader left: settings\nHeader right: exit\nDouble tap: exit\nBottom row: slower WPM — browse — faster WPM\nLong-press: settings\nSwipe up/down: WPM (optional)\nSwipe left/right: jump words while playing, or browse when paused\n\nPreview:\nTap word: set current word\nFooter left/right: prev/next page\nFooter center or header Back: return"),
                timeout = 8,
            })
        end,
    })

    -- WPM
    table.insert(items, {
        text = _("Words per minute"),
        mandatory = tostring(s:get("wpm")),
        callback = function()
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
                self:_refresh()
            end,
        })
    end,
    })

    -- Font size
    table.insert(items, {
        text = _("Font size"),
        mandatory = s:get("font_size"),
        callback = function() self:_cycle("font_size", {"small", "medium", "large"}) end,
    })

    -- Typeface
    table.insert(items, {
        text = _("Typeface"),
        mandatory = s:get("typeface"),
        callback = function() self:_cycle("typeface", {"default", "atkinson", "opendyslexic"}) end,
    })

    -- Theme
    table.insert(items, {
        text = _("Theme"),
        mandatory = s:get("theme"),
        callback = function() self:_cycle("theme", {"light", "dark"}) end,
    })

    -- Anchor position
    table.insert(items, {
        text = _("Anchor position"),
        mandatory = tostring(s:get("anchor_position")) .. "%",
        callback = function()
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
                self:_refresh()
            end,
        })
    end,
    })

    -- Anchor style
    table.insert(items, {
        text = _("Anchor style"),
        mandatory = s:get("anchor_style"),
        callback = function() self:_cycle("anchor_style", {"invert", "bold", "underline", "none"}) end,
    })

    -- Anchor guide lines
    table.insert(items, {
        text = _("Anchor guide lines"),
        mandatory = boolLabel(s:get("anchor_guides")),
        callback = function()
        s:set("anchor_guides", not s:get("anchor_guides"))
        self:_refresh()
    end,
    })

    -- Phantom words
    table.insert(items, {
        text = _("Phantom words"),
        mandatory = boolLabel(s:get("phantom_words")),
        callback = function()
        s:set("phantom_words", not s:get("phantom_words"))
        self:_refresh()
    end,
    })

    -- Letter spacing
    table.insert(items, {
        text = _("Letter spacing"),
        mandatory = tostring(s:get("letter_spacing")) .. "px",
        callback = function()
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
                self:_refresh()
            end,
        })
    end,
    })

    -- Pacing: long words
    table.insert(items, {
        text = _("Pacing: long words"),
        mandatory = boolLabel(s:get("pacing_long_words")),
        callback = function()
        s:set("pacing_long_words", not s:get("pacing_long_words"))
        self:_refresh()
    end,
    })

    -- Pacing: complexity
    table.insert(items, {
        text = _("Pacing: complex words"),
        mandatory = boolLabel(s:get("pacing_complexity")),
        callback = function()
        s:set("pacing_complexity", not s:get("pacing_complexity"))
        self:_refresh()
    end,
    })

    -- Pacing: punctuation
    table.insert(items, {
        text = _("Pacing: punctuation"),
        mandatory = boolLabel(s:get("pacing_punctuation")),
        callback = function()
        s:set("pacing_punctuation", not s:get("pacing_punctuation"))
        self:_refresh()
    end,
    })

    -- Books folder
    table.insert(items, {
        text = _("Books folder"),
        mandatory = _("Change"),
        callback = function()
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
                        self:_refresh()
                    end,
                },
            }},
        }
        UIManager:show(dialog)
    end,
    })

    -- Reset all
    table.insert(items, {
        text = _("Reset all settings"),
        mandatory = "",
        callback = function()
        UIManager:show(ConfirmBox:new{
            text        = _("Reset all FlowRead settings to defaults?"),
            ok_text     = _("Reset"),
            ok_callback = function()
                s:reset()
                self:_refresh()
                UIManager:show(InfoMessage:new{ text = _("Settings reset."), timeout = 2 })
            end,
        })
    end,
    })

    return items
end

function SettingsPanel:onClose()
    if self._closed then return true end
    self._closed = true
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

SettingsPanel.onReturn = SettingsPanel.onClose

return SettingsPanel
