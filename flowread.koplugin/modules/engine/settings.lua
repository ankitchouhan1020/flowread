local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger      = require("logger")

local DEFAULTS = {
    -- Reading speed
    wpm                  = 250,

    -- ORP / anchor
    anchor_position      = 50,          -- % from left edge (50 = center)
    anchor_style         = "invert",    -- "invert" | "bold" | "underline" | "none"
    anchor_guides        = true,        -- vertical guide lines above/below ORP

    -- Context
    phantom_words        = false,       -- show previous/next word dimly

    -- Typography
    font_size            = "medium",    -- "small" | "medium" | "large"
    typeface             = "default",   -- "default" | "atkinson" | "opendyslexic"

    -- Theme (overrides KOReader theme for the RSVP screen)
    theme                = "light",     -- "light" | "dark"

    -- Intelligent pacing
    pacing_long_words    = true,
    pacing_complexity    = true,
    pacing_punctuation   = true,

    -- Reading mode
    reading_mode         = "rsvp",      -- "rsvp" | "scroll"

    -- Letter spacing (pixels of extra gap added between each character)
    letter_spacing       = 0,           -- -4 .. +12 in steps of 2

    -- Library
    -- Overridden at runtime by Settings:new() based on detected device mount point
    books_path           = "/mnt/us/books",
}

local Settings = {}
Settings.__index = Settings

local function detectBooksPath()
    local lfs = require("libs/libkoreader-lfs")
    -- Kindle native jailbreak mount
    if lfs.attributes("/mnt/us") then return "/mnt/us/books" end
    -- Android / Kobo / PocketBook via KOReader home_dir
    local ok, Device = pcall(require, "device")
    if ok and Device.home_dir and Device.home_dir ~= "" then
        return Device.home_dir .. "/books"
    end
    return "/sdcard/books"
end

function Settings:new()
    local o = setmetatable({}, self)
    local path = DataStorage:getSettingsDir() .. "/flowread.lua"
    o._store = LuaSettings:open(path)
    logger.info("FlowRead: settings loaded from " .. path)
    return o
end

function Settings:get(key)
    local v = self._store:readSetting(key)
    if v == nil then
        if key == "books_path" then return detectBooksPath() end
        return DEFAULTS[key]
    end
    return v
end

function Settings:set(key, value)
    self._store:saveSetting(key, value)
    self._store:flush()
end

---Save to in-memory store without flushing to disk.
---Use for high-frequency updates (e.g. WPM on every swipe) where the value
---will be flushed on the next explicit Settings:flush() or savePosition() call.
function Settings:setDeferred(key, value)
    self._store:saveSetting(key, value)
end

---Explicitly flush all pending deferred writes to disk.
function Settings:flush()
    self._store:flush()
end

function Settings:reset()
    for k, v in pairs(DEFAULTS) do
        self._store:saveSetting(k, v)
    end
    self._store:flush()
end

-- Per-book position persistence -----------------------------------------

function Settings:_positionKey(file_path)
    -- Simple hash to keep key length manageable
    local h = 5381
    for i = 1, #file_path do
        h = (h * 33 + file_path:byte(i)) % 0x100000000
    end
    return string.format("pos_%08x", h)
end

function Settings:savePosition(file_path, word_index, total_words)
    local key = self:_positionKey(file_path)
    self._store:saveSetting(key, {
        path        = file_path,
        word_index  = word_index,
        total_words = total_words,
        timestamp   = os.time(),
    })
    self._store:flush()
end

function Settings:getPosition(file_path)
    local key = self:_positionKey(file_path)
    return self._store:readSetting(key)
end

function Settings:clearPosition(file_path)
    local key = self:_positionKey(file_path)
    self._store:delSetting(key)
    self._store:flush()
end

-- Font size in points for the RSVP word display -------------------------

function Settings:getFontSizePt()
    local map = { small = 44, medium = 60, large = 80 }
    return map[self:get("font_size")] or 60
end

function Settings:getPhantomFontSizePt()
    return math.floor(self:getFontSizePt() * 0.55)
end

return Settings
