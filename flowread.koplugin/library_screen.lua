local Menu        = require("ui/widget/menu")
local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local Screen      = require("device").screen
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local _           = require("gettext")

local SettingsPanel = require("settings_panel")

-- File extensions supported by the document parser
local SUPPORTED_EXT = {
    epub     = true,
    txt      = true,
    md       = true,
    markdown = true,
    fb2      = true,
    html     = true,
    htm      = true,
    xhtml    = true,
}

local LibraryScreen = Menu:extend{
    name             = "rsvp_library",
    covers_fullscreen = true,
    is_borderless    = false,
}

function LibraryScreen:init(o)
    o = o or {}
    self.settings = o.settings
    self.title    = _("FlowRead")
    self.width    = Screen:getWidth()
    self.height   = Screen:getHeight()

    self.item_table = self:_scanLibrary()
    Menu.init(self)
end

-- Scan the configured books folder and return Menu item_table
function LibraryScreen:_scanLibrary()
    local items = {}

    -- Settings item at top
    table.insert(items, {
        text      = _("⚙  Settings"),
        mandatory = "",
        callback  = function()
            UIManager:show(SettingsPanel:new{
                settings       = self.settings,
                refresh_parent = function() self:_refresh() end,
            })
        end,
    })

    local books_path = self.settings:get("books_path")
    local attr = lfs.attributes(books_path)
    if not attr or attr.mode ~= "directory" then
        table.insert(items, {
            text      = _("Books folder not found:"),
            mandatory = books_path,
            callback  = function() end,
        })
        table.insert(items, {
            text      = _("→ Change folder in Settings"),
            mandatory = "",
            callback  = function()
                UIManager:show(SettingsPanel:new{
                    settings       = self.settings,
                    refresh_parent = function() self:_refresh() end,
                })
            end,
        })
        return items
    end

    local found = {}
    self:_scanDir(books_path, found)

    table.sort(found, function(a, b)
        -- Sort by last-read timestamp descending, then alphabetically
        local pa = self.settings:getPosition(a.path)
        local pb = self.settings:getPosition(b.path)
        local ta = pa and pa.timestamp or 0
        local tb = pb and pb.timestamp or 0
        if ta ~= tb then return ta > tb end
        return a.title:lower() < b.title:lower()
    end)

    if #found == 0 then
        table.insert(items, {
            text      = _("No supported books found in"),
            mandatory = books_path,
            callback  = function() end,
        })
        return items
    end

    for _, book in ipairs(found) do
        local saved    = self.settings:getPosition(book.path)
        local progress = ""
        if saved and saved.total_words and saved.total_words > 0 then
            local pct = math.floor(saved.word_index / saved.total_words * 100)
            progress = pct .. "%"
        end

        local mandatory = book.ext:upper()
        if progress ~= "" then
            mandatory = progress .. "  " .. mandatory
        end

        -- Closure captures book.path
        local file_path = book.path
        table.insert(items, {
            text         = book.title,
            mandatory    = mandatory,
            hold_callback = function()
                self:_showBookMenu(file_path, book.title)
            end,
            callback     = function()
                self:_openBook(file_path)
            end,
        })
    end

    return items
end

-- Recursive directory scan (depth-limited to avoid SD card traversal)
function LibraryScreen:_scanDir(dir_path, results, depth)
    depth = depth or 0
    if depth > 2 then return end

    for entry in lfs.dir(dir_path) do
        if entry ~= "." and entry ~= ".." then
            local full = dir_path .. "/" .. entry
            local attr = lfs.attributes(full)
            if attr then
                if attr.mode == "directory" then
                    self:_scanDir(full, results, depth + 1)
                elseif attr.mode == "file" then
                    local ext = entry:match("%.([^%.]+)$")
                    if ext and SUPPORTED_EXT[ext:lower()] then
                        local title = entry:gsub("%." .. ext .. "$", "")
                                          :gsub("[_%-]", " ")
                        table.insert(results, {
                            path  = full,
                            title = title,
                            ext   = ext:lower(),
                        })
                    end
                end
            end
        end
    end
end

function LibraryScreen:_openBook(file_path)
    local DocumentParser = require("document_parser")
    local RSVPEngine     = require("rsvp_engine")

    local loading = InfoMessage:new{ text = _("Loading…"), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local result, err = DocumentParser:parse(file_path)

    UIManager:close(loading)

    if not result or not result.words or #result.words == 0 then
        UIManager:show(InfoMessage:new{
            text    = _("Could not extract text.\n") .. (err or ""),
            timeout = 4,
        })
        return
    end

    local engine = RSVPEngine:new{
        words    = result.words,
        chapters = result.chapters,
        settings = self.settings,
    }

    local saved = self.settings:getPosition(file_path)
    if saved and saved.word_index and saved.word_index > 1 then
        local pct = math.floor(saved.word_index / #result.words * 100)
        UIManager:show(ConfirmBox:new{
            text        = string.format(_("Resume from %d%%?"), pct),
            ok_text     = _("Resume"),
            cancel_text = _("From beginning"),
            ok_callback = function()
                engine.current_idx = math.min(saved.word_index, #result.words)
                self:_openReadingScreen(engine, file_path)
            end,
            cancel_callback = function()
                self:_openReadingScreen(engine, file_path)
            end,
        })
    else
        self:_openReadingScreen(engine, file_path)
    end
end

-- Dispatch to RSVPScreen or ScrollScreen based on the reading_mode setting.
function LibraryScreen:_openReadingScreen(engine, file_path)
    local mode = self.settings:get("reading_mode")
    local ScreenClass
    if mode == "scroll" then
        ScreenClass = require("scroll_screen")
    else
        ScreenClass = require("rsvp_screen")
    end
    UIManager:show(ScreenClass:new{
        engine    = engine,
        settings  = self.settings,
        file_path = file_path,
    })
end

function LibraryScreen:_showBookMenu(file_path, title)
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    local dialog
    dialog = ButtonDialogTitle:new{
        title   = title,
        buttons = {
            {
                {
                    text     = _("Open"),
                    callback = function()
                        UIManager:close(dialog)
                        self:_openBook(file_path)
                    end,
                },
                {
                    text     = _("Clear progress"),
                    callback = function()
                        UIManager:close(dialog)
                        self.settings:clearPosition(file_path)
                        self:_refresh()
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
end

function LibraryScreen:_refresh()
    self:switchItemTable(nil, self:_scanLibrary())
end

function LibraryScreen:onReturn()
    UIManager:close(self)
    return true
end

return LibraryScreen
