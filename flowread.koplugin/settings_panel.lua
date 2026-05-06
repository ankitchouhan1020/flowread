local UIManager   = require("ui/uimanager")
local Menu        = require("ui/widget/menu")
local SpinWidget  = require("ui/widget/spinwidget")
local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Screen      = require("device").screen
local _           = require("gettext")

local SettingsPanel = Menu:extend{
    name             = "rsvp_settings",
    is_borderless    = false,
    covers_fullscreen = true,
}

-- Helper: cycle through a table of options and save
local function cycleOption(settings, key, options)
    local current = settings:get(key)
    local idx = 1
    for i, v in ipairs(options) do
        if v == current then idx = i; break end
    end
    local next_idx = (idx % #options) + 1
    settings:set(key, options[next_idx])
end

local function boolLabel(v)
    return v and _("On") or _("Off")
end

function SettingsPanel:init(o)
    o = o or {}
    self.settings       = o.settings
    self.refresh_parent = o.refresh_parent  -- optional callback
    self.title          = _("RSVP Settings")
    self.width          = Screen:getWidth()
    self.height         = Screen:getHeight()
    self.item_table     = self:_buildItems()
    Menu.init(self)
end

function SettingsPanel:_buildItems()
    local s = self.settings
    local items = {}

    -- WPM
    table.insert(items, {
        text      = _("Words per minute"),
        mandatory = tostring(s:get("wpm")),
        callback  = function()
            UIManager:show(SpinWidget:new{
                title_text       = _("Words per minute"),
                value            = s:get("wpm"),
                value_min        = 60,
                value_max        = 800,
                value_step       = 10,
                ok_always_enabled = true,
                callback         = function(spin)
                    s:set("wpm", spin.value)
                    self:_refresh()
                end,
            })
        end,
    })

    -- Anchor position
    table.insert(items, {
        text      = _("Anchor position (% from left)"),
        mandatory = tostring(s:get("anchor_position")) .. "%",
        callback  = function()
            UIManager:show(SpinWidget:new{
                title_text        = _("Anchor position"),
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
        text      = _("Anchor style"),
        mandatory = s:get("anchor_style"),
        callback  = function()
            cycleOption(s, "anchor_style", {"invert", "bold", "underline", "none"})
            self:_refresh()
        end,
    })

    -- Anchor guides
    table.insert(items, {
        text      = _("Anchor guide lines"),
        mandatory = boolLabel(s:get("anchor_guides")),
        callback  = function()
            s:set("anchor_guides", not s:get("anchor_guides"))
            self:_refresh()
        end,
    })

    -- Phantom words
    table.insert(items, {
        text      = _("Phantom words (context)"),
        mandatory = boolLabel(s:get("phantom_words")),
        callback  = function()
            s:set("phantom_words", not s:get("phantom_words"))
            self:_refresh()
        end,
    })

    -- Font size
    table.insert(items, {
        text      = _("Font size"),
        mandatory = s:get("font_size"),
        callback  = function()
            cycleOption(s, "font_size", {"small", "medium", "large"})
            self:_refresh()
        end,
    })

    -- Typeface
    table.insert(items, {
        text      = _("Typeface"),
        mandatory = s:get("typeface"),
        callback  = function()
            cycleOption(s, "typeface", {"default", "atkinson", "opendyslexic"})
            self:_refresh()
        end,
    })

    -- Letter spacing (tracking)
    table.insert(items, {
        text      = _("Letter spacing"),
        mandatory = tostring(s:get("letter_spacing")) .. "px",
        callback  = function()
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

    -- Reading mode
    table.insert(items, {
        text      = _("Reading mode"),
        mandatory = s:get("reading_mode"),
        callback  = function()
            cycleOption(s, "reading_mode", {"rsvp", "scroll"})
            self:_refresh()
        end,
    })

    -- Theme
    table.insert(items, {
        text      = _("Theme"),
        mandatory = s:get("theme"),
        callback  = function()
            cycleOption(s, "theme", {"light", "dark"})
            self:_refresh()
        end,
    })

    -- Pacing: long words
    table.insert(items, {
        text      = _("Pacing: extra time for long words"),
        mandatory = boolLabel(s:get("pacing_long_words")),
        callback  = function()
            s:set("pacing_long_words", not s:get("pacing_long_words"))
            self:_refresh()
        end,
    })

    -- Pacing: complexity
    table.insert(items, {
        text      = _("Pacing: extra time for complex words"),
        mandatory = boolLabel(s:get("pacing_complexity")),
        callback  = function()
            s:set("pacing_complexity", not s:get("pacing_complexity"))
            self:_refresh()
        end,
    })

    -- Pacing: punctuation
    table.insert(items, {
        text      = _("Pacing: pause at punctuation"),
        mandatory = boolLabel(s:get("pacing_punctuation")),
        callback  = function()
            s:set("pacing_punctuation", not s:get("pacing_punctuation"))
            self:_refresh()
        end,
    })

    -- Books folder
    table.insert(items, {
        text      = _("Books folder"),
        mandatory = s:get("books_path"),
        callback  = function()
            local InputDialog = require("ui/widget/inputdialog")
            local dialog
            dialog = InputDialog:new{
                title       = _("Books folder path"),
                input       = s:get("books_path"),
                input_type  = "string",
                buttons     = {
                    {
                        {
                            text     = _("Cancel"),
                            callback = function() UIManager:close(dialog) end,
                        },
                        {
                            text     = _("Save"),
                            is_enter_default = true,
                            callback = function()
                                local path = dialog:getInputText()
                                if path and path ~= "" then
                                    s:set("books_path", path)
                                end
                                UIManager:close(dialog)
                                self:_refresh()
                            end,
                        },
                    }
                },
            }
            UIManager:show(dialog)
        end,
    })

    -- Reset
    table.insert(items, {
        text      = _("Reset all settings to defaults"),
        mandatory = "",
        callback  = function()
            UIManager:show(ConfirmBox:new{
                text     = _("Reset all FlowRead settings to defaults?"),
                ok_text  = _("Reset"),
                ok_callback = function()
                    s:reset()
                    self:_refresh()
                    UIManager:show(InfoMessage:new{
                        text    = _("Settings reset."),
                        timeout = 2,
                    })
                end,
            })
        end,
    })

    return items
end

function SettingsPanel:_refresh()
    -- Rebuild the item list to show updated mandatory values
    self:switchItemTable(nil, self:_buildItems())
    if self.refresh_parent then
        self.refresh_parent()
    end
end

function SettingsPanel:onReturn()
    UIManager:close(self)
    return true
end

return SettingsPanel
