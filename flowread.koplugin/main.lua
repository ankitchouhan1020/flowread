local WidgetContainer = require("ui/widget/widgetcontainer")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")
local _               = require("gettext")

local Settings      = require("flowread/settings")
local LibraryScreen = require("flowread/library_screen")

local FlowReadPlugin = WidgetContainer:extend{
    name        = "flowread",
    fullname    = _("FlowRead"),
    -- Available from FileManager (no open document required)
    is_doc_only = false,
}

function FlowReadPlugin:init()
    self.settings = Settings:new()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    logger.info("FlowRead: plugin loaded")
end

function FlowReadPlugin:addToMainMenu(menu_items)
    menu_items.flowread = {
        text         = _("FlowRead"),
        sorting_hint = "tools",
        callback     = function()
            self:openLibrary()
        end,
    }
end

function FlowReadPlugin:openLibrary()
    local library = LibraryScreen:new{
        settings = self.settings,
    }
    UIManager:show(library)
end

-- Allow opening a specific book directly (e.g. from a future ReaderUI hook)
function FlowReadPlugin:openBook(file_path)
    local DocumentParser = require("flowread/document_parser")
    local RSVPEngine     = require("flowread/rsvp_engine")

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
        settings = self.settings,
    }

    -- Restore saved position
    local saved = self.settings:getPosition(file_path)
    if saved and saved.word_index and saved.word_index > 1 then
        engine.current_idx = math.min(saved.word_index, #result.words)
    end

    local mode = self.settings:get("reading_mode")
    local ScreenClass = (mode == "scroll")
        and require("flowread/scroll_screen")
        or  require("flowread/rsvp_screen")

    local screen = ScreenClass:new{
        engine    = engine,
        settings  = self.settings,
        file_path = file_path,
    }
    UIManager:show(screen)
end

return FlowReadPlugin
