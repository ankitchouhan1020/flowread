--[[
StartReadingMenu
================
Full-screen "Start Reading" menu: resume, beginning, word browse, chapters.
Used from the library after opening a book, and from the RSVP scrub Overview.
--]]

local Menu      = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Device    = require("device")
local Screen    = Device.screen
local _         = require("gettext")

local StartReadingMenu = {}

--- Show the Start Reading selector.
---@param o table
---   settings       Settings instance
---   engine         RSVPEngine
---   file_path      string
---   on_reading_ready  function()  seek + menu close already done for word-picker;
---                     for Resume/Beginning seek is done before this runs.
---                     Library: open RSVP reader. In-reader: refresh RSVP only.
function StartReadingMenu.show(o)
    local settings  = o.settings
    local engine    = o.engine
    local file_path = o.file_path or ""
    local on_ready  = o.on_reading_ready or function() end

    local selector
    local ScrubPreview = require("modules/ui/scrub_preview")

    local function startAt(idx)
        engine:seekTo(idx)
        if selector then UIManager:close(selector) end
        on_ready()
    end

    local function chooseWordAt(idx)
        engine:seekTo(idx)
        UIManager:show(ScrubPreview:new{
            engine      = engine,
            settings    = settings,
            file_path   = file_path,
            select_mode = true,
            on_select   = function()
                if selector then UIManager:close(selector) end
                on_ready()
            end,
        })
    end

    local items = {}
    local saved = settings:getPosition(file_path)
    if saved and saved.word_index and saved.word_index > 1 then
        local pct = math.floor(saved.word_index / #engine.words * 100)
        table.insert(items, {
            text = _("Resume"),
            mandatory = pct .. "%",
            callback = function() startAt(saved.word_index) end,
        })
    end
    table.insert(items, {
        text = _("Beginning"),
        mandatory = "0%",
        callback = function() startAt(1) end,
    })
    table.insert(items, {
        text = _("Choose exact word"),
        mandatory = _("Browse"),
        callback = function()
            local pos = settings:getPosition(file_path)
            chooseWordAt(pos and pos.word_index or 1)
        end,
    })
    if engine.chapters and #engine.chapters > 0 then
        for i, ch in ipairs(engine.chapters) do
            local title = ch.title or string.format(_("Chapter %d"), i)
            if #title > 42 then title = title:sub(1, 39) .. "..." end
            table.insert(items, {
                text = title,
                mandatory = tostring(i),
                callback = function() chooseWordAt(ch.start_idx) end,
            })
        end
    end

    selector = Menu:new{
        title = _("Start Reading"),
        item_table = items,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        is_borderless = true,
        is_popout = false,
    }
    UIManager:show(selector)
end

return StartReadingMenu
