--[[
ChaptersScreen
==============
A Menu-based widget that lists all chapters detected in the current book.
Tapping a chapter seeks the engine to that chapter's start word and closes
the screen. The `on_return` callback is called so the parent reading screen
can repaint itself at the new position.
--]]

local Menu    = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Screen  = require("device").screen
local _       = require("gettext")

local ChaptersScreen = Menu:extend{
    name             = "rsvp_chapters",
    covers_fullscreen = true,
    is_borderless    = false,
}

function ChaptersScreen:init(o)
    o = o or {}
    self.engine    = o.engine
    self.on_return = o.on_return   -- callback(chapter_n) after seek

    self.title  = _("Chapters")
    self.width  = Screen:getWidth()
    self.height = Screen:getHeight()

    self.item_table = self:_buildItems()
    Menu.init(self)
end

function ChaptersScreen:_buildItems()
    local engine   = self.engine
    local chapters = engine.chapters or {}
    local items    = {}

    -- Current chapter (for marking)
    local _, current_n = engine:currentChapter()

    for n, ch in ipairs(chapters) do
        local is_current = (n == current_n)

        -- Progress of this chapter: if next chapter exists, use its start - 1
        local ch_end = (chapters[n + 1] and chapters[n + 1].start_idx - 1)
                    or #engine.words
        local ch_len = math.max(1, ch_end - ch.start_idx + 1)

        local pct = 0
        if engine.current_idx >= ch.start_idx and engine.current_idx <= ch_end then
            pct = math.floor((engine.current_idx - ch.start_idx) / ch_len * 100)
        elseif engine.current_idx > ch_end then
            pct = 100
        end

        local mandatory = string.format("%d%%", pct)
        if is_current then mandatory = "-> " .. mandatory end

        local chapter_n = n  -- capture for closure
        table.insert(items, {
            text      = ch.title,
            mandatory = mandatory,
            callback  = function()
                engine:jumpToChapter(chapter_n)
                UIManager:close(self)
                if self.on_return then self.on_return(chapter_n) end
            end,
        })
    end

    if #items == 0 then
        table.insert(items, {
            text      = _("No chapters found"),
            mandatory = "",
            callback  = function() end,
        })
    end

    return items
end

function ChaptersScreen:onReturn()
    UIManager:close(self)
    return true
end

return ChaptersScreen
