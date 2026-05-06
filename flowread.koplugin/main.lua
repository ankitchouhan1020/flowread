local ok_widget, WidgetContainer = pcall(require, "ui/widget/container/widgetcontainer")
if not ok_widget then
    WidgetContainer = require("ui/widget/widgetcontainer")
end
local Dispatcher = require("dispatcher")
local UIManager  = require("ui/uimanager")
local logger     = require("logger")
local _          = require("gettext")

local FlowReadPlugin = WidgetContainer:extend{
    name        = "flowread",
    fullname    = _("FlowRead"),
    is_doc_only = false,
}

function FlowReadPlugin:init()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    logger.info("FlowRead: plugin loaded")
end

function FlowReadPlugin:addToMainMenu(menu_items)
    menu_items.flowread = {
        text         = _("FlowRead"),
        sorting_hint = "more_tools",
        callback     = function()
            self:openLibrary()
        end,
    }
end

function FlowReadPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("flowread_open", {
        category = "none",
        event    = "FlowReadOpen",
        title    = _("Open FlowRead"),
        general  = true,
    })
end

function FlowReadPlugin:onFlowReadOpen()
    self:openLibrary()
    return true
end

function FlowReadPlugin:_getSettings()
    if not self._cached_settings then
        local Settings = require("modules/engine/settings")
        self._cached_settings = Settings:new()
    end
    return self._cached_settings
end

function FlowReadPlugin:openLibrary()
    local ok, LibraryScreen = pcall(require, "modules/ui/library_screen")
    if not ok then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text    = "FlowRead: failed to load:\n" .. tostring(LibraryScreen),
            timeout = 5,
        })
        return
    end
    UIManager:show(LibraryScreen:new{ settings = self:_getSettings() })
end

function FlowReadPlugin:openBook(file_path)
    local ok_dp, DocumentParser = pcall(require, "modules/engine/document_parser")
    local ok_eng, RSVPEngine    = pcall(require, "modules/engine/rsvp_engine")
    if not ok_dp or not ok_eng then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text    = _("FlowRead: failed to load reading engine."),
            timeout = 3,
        })
        return
    end

    local settings = self:_getSettings()
    local result, err = DocumentParser:parse(file_path)
    if not result or not result.words or #result.words == 0 then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text    = _("Could not extract text from this file.\n") .. (err or ""),
            timeout = 3,
        })
        return
    end

    local engine = RSVPEngine:new{
        words    = result.words,
        chapters = result.chapters,
        settings = settings,
    }

    local saved = settings:getPosition(file_path)
    if saved and saved.word_index and saved.word_index > 1 then
        engine.current_idx = math.min(saved.word_index, #result.words)
    end

    local ok_sc, ScreenClass = pcall(require, "modules/ui/rsvp_screen")
    if not ok_sc then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text    = _("FlowRead: failed to load reading screen."),
            timeout = 3,
        })
        return
    end

    UIManager:show(ScreenClass:new{
        engine    = engine,
        settings  = settings,
        file_path = file_path,
    })
end

return FlowReadPlugin
