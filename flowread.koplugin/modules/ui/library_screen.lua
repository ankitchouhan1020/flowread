local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
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
local VerticalSpan    = require("ui/widget/verticalspan")
local lfs             = require("libs/libkoreader-lfs")
local _               = require("gettext")

local Screen = Device.screen

local PAD       = Screen:scaleBySize(8)
local ROW_H     = Screen:scaleBySize(58)
local TITLE_FACE = Font:getFace("cfont", 17)
local BADGE_FACE = Font:getFace("smallinfofontbold", 14)

local SUPPORTED_EXT = {
    epub = true, txt = true, md = true, markdown = true,
    fb2  = true, html = true, htm = true, xhtml = true,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- BookRow: a tappable row representing one book
-- ─────────────────────────────────────────────────────────────────────────────
local BookRow = InputContainer:extend{
    title         = "",
    badge         = "",
    width         = 0,
    tap_callback  = nil,
    hold_callback = nil,
}

function BookRow:init()
    local dimen = Geom:new{ x = 0, y = 0, w = self.width, h = ROW_H }
    self.dimen = dimen

    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = dimen } },
    }

    local inner_w = self.width - PAD * 2
    local badge_w = Screen:scaleBySize(72)
    local title_w = inner_w - badge_w - PAD

    self[1] = FrameContainer:new{
        width      = self.width,
        height     = ROW_H,
        padding    = PAD,
        margin     = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            TextBoxWidget:new{
                text          = self.title,
                face          = TITLE_FACE,
                width         = title_w,
                height        = ROW_H - PAD * 2,
                height_adjust = true,
                alignment     = "left",
            },
            HorizontalSpan:new{ width = PAD },
            CenterContainer:new{
                dimen = Geom:new{ w = badge_w, h = ROW_H - PAD * 2 },
                TextWidget:new{ text = self.badge, face = BADGE_FACE },
            },
        },
    }
end

function BookRow:onTap()
    if self.tap_callback then self.tap_callback() end
    return true
end

function BookRow:onHold()
    if self.hold_callback then self.hold_callback() end
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- LibraryScreen: fullscreen library overlay
-- ─────────────────────────────────────────────────────────────────────────────
local LibraryScreen = InputContainer:extend{
    name = "flowread_library",
}

function LibraryScreen:init()
    self.key_events = {
        Close = { { "Back" }, doc = "close FlowRead" },
    }
    self:_buildUI()
end

function LibraryScreen:_buildUI()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local title_bar = TitleBar:new{
        width                  = screen_w,
        title                  = _("FlowRead"),
        with_bottom_line       = true,
        left_icon              = "appbar.settings",
        left_icon_tap_callback = function() self:_openSettings() end,
        close_callback         = function() self:onClose() end,
        show_parent            = self,
    }
    local title_h = title_bar:getSize().h

    -- Build the book list rows
    local rows = VerticalGroup:new{ align = "left" }
    local books = self:_scanLibrary()

    if #books == 0 then
        local books_path = self.settings:get("books_path")
        table.insert(rows, VerticalSpan:new{ width = PAD * 4 })
        table.insert(rows, CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = ROW_H },
            TextWidget:new{
                text = _("No books found in:") .. "\n" .. books_path,
                face = TITLE_FACE,
            },
        })
        table.insert(rows, VerticalSpan:new{ width = PAD * 2 })
        table.insert(rows, CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = ROW_H },
            Button:new{
                text     = _("Change folder in Settings"),
                callback = function() self:_openSettings() end,
            },
        })
    else
        for i, book in ipairs(books) do
            local saved = self.settings:getPosition(book.path)
            local badge = book.ext:upper()
            if saved and saved.total_words and saved.total_words > 0 then
                local pct = math.floor(saved.word_index / saved.total_words * 100)
                badge = pct .. "%  " .. badge
            end

            local file_path = book.path
            local row = BookRow:new{
                title         = book.title,
                badge         = badge,
                width         = screen_w,
                tap_callback  = function() self:_openBook(file_path) end,
                hold_callback = function() self:_showBookMenu(file_path, book.title) end,
            }
            table.insert(rows, row)
            if i < #books then
                table.insert(rows, LineWidget:new{
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                    dimen      = Geom:new{ w = screen_w, h = Size.line.thin },
                })
            end
        end
    end

    -- Wrap rows in a scrollable area
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
        -- Fallback: plain frame if ScrollableContainer unavailable
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

function LibraryScreen:_scanLibrary()
    local books_path = self.settings:get("books_path")
    local attr = lfs.attributes(books_path)
    if not attr or attr.mode ~= "directory" then return {} end

    local found = {}
    self:_scanDir(books_path, found)

    table.sort(found, function(a, b)
        local pa = self.settings:getPosition(a.path)
        local pb = self.settings:getPosition(b.path)
        local ta = pa and pa.timestamp or 0
        local tb = pb and pb.timestamp or 0
        if ta ~= tb then return ta > tb end
        return a.title:lower() < b.title:lower()
    end)

    return found
end

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
                        local title = entry:gsub("%." .. ext .. "$", ""):gsub("[_%-]", " ")
                        table.insert(results, { path = full, title = title, ext = ext:lower() })
                    end
                end
            end
        end
    end
end

function LibraryScreen:_openBook(file_path)
    local loading = InfoMessage:new{ text = _("Loading…"), timeout = 0 }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local ok, err = pcall(function()
        local DocumentParser = require("modules/engine/document_parser")
        local RSVPEngine     = require("modules/engine/rsvp_engine")

        local result, parse_err = DocumentParser:parse(file_path)
        UIManager:close(loading)

        if not result or not result.words or #result.words == 0 then
            UIManager:show(InfoMessage:new{
                text    = _("Could not extract text.\n") .. (parse_err or ""),
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
                    self:_startReading(engine, file_path)
                end,
                cancel_callback = function()
                    self:_startReading(engine, file_path)
                end,
            })
        else
            self:_startReading(engine, file_path)
        end
    end)

    if not ok then
        UIManager:close(loading)
        UIManager:show(InfoMessage:new{
            text    = "FlowRead error:\n" .. tostring(err),
            timeout = 6,
        })
    end
end

function LibraryScreen:_startReading(engine, file_path)
    local mode = self.settings:get("reading_mode")
    local ok_sc, ScreenClass
    if mode == "scroll" then
        ok_sc, ScreenClass = pcall(require, "modules/ui/scroll_screen")
    else
        ok_sc, ScreenClass = pcall(require, "modules/ui/rsvp_screen")
    end
    if not ok_sc then
        UIManager:show(InfoMessage:new{
            text    = "FlowRead: failed to load reading screen.\n" .. tostring(ScreenClass),
            timeout = 5,
        })
        return
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

function LibraryScreen:_openSettings()
    local SettingsPanel = require("modules/ui/settings_panel")
    UIManager:show(SettingsPanel:new{
        settings = self.settings,
        on_close = function() self:_refresh() end,
    })
end

function LibraryScreen:_refresh()
    self:_buildUI()
    UIManager:setDirty(self, "ui")
end

function LibraryScreen:onClose()
    UIManager:close(self)
    return true
end

return LibraryScreen
