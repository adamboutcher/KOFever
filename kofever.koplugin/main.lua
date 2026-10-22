--[[--
KOFever: read FreshRSS articles offline through the Fever API.

Syncs unread articles to a local cache, shows them as plain text, and queues reads
made offline so they are marked read on the server at the next sync.

@module koplugin.kofever
--]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

-- The plugin directory is only on package.path while main.lua is loading,
-- so the plugin's own modules must be required here at the top.
local FeverClient = require("kofever_client")
local FeverHtml = require("kofever_html")
local FeverStore = require("kofever_store")
local FeverSync = require("kofever_sync")

-- Maximum number of articles kept in the local cache.
local MAX_CACHED_ITEMS = 200
-- When true, opened articles stay in the list with a marker instead of disappearing.
local SHOW_OPENED_ARTICLES = false
-- Feed names longer than this are shortened in the article list.
local MAX_FEED_TITLE_CHARS = 24

local SETTINGS_FILE = "kofever_settings.lua"
local CACHE_FILE = "kofever_cache.lua"

-- Shared by every plugin instance (file manager and reader), loaded on first use.
local shared_store

local function getStore()
    if not shared_store then
        shared_store = FeverStore:new{ file = DataStorage:getSettingsDir() .. "/" .. CACHE_FILE }
    end
    return shared_store
end

local function shorten(text, max_chars)
    local chars = util.splitToChars(text)
    if #chars <= max_chars then
        return text
    end
    return table.concat(chars, "", 1, max_chars - 1) .. "…"
end

local function errorMessage(err)
    local kind = err and err.kind
    if kind == "auth" then
        return _("The server rejected the login. Check the username and API password.")
    elseif kind == "http" then
        return T(_("The server returned an error (%1). Check the server URL."), err.detail)
    elseif kind == "json" then
        return _("The server sent an unexpected response. Check the server URL and that the Fever API is enabled in FreshRSS.")
    end
    return _("Could not reach the server. Check the Wi-Fi connection and the server URL.")
end

local KOFever = WidgetContainer:extend{
    name = "kofever",
    is_doc_only = false,
}

function KOFever:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. SETTINGS_FILE)
    self.ui.menu:registerToMainMenu(self)
end

function KOFever:addToMainMenu(menu_items)
    menu_items.kofever = {
        text = _("KOFever"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync now"),
                callback = function()
                    self:syncNow()
                end,
            },
            {
                text = _("Browse unread articles"),
                callback = function()
                    self:showArticleList()
                end,
            },
            {
                text = _("Server login"),
                keep_menu_open = true,
                callback = function()
                    self:showLoginDialog()
                end,
            },
        },
    }
end

function KOFever:isConfigured()
    local server = self.settings:readSetting("server")
    local api_key = self.settings:readSetting("api_key")
    return server and server ~= "" and api_key and api_key ~= ""
end

function KOFever:getClient()
    return FeverClient:new{
        server = self.settings:readSetting("server"),
        api_key = self.settings:readSetting("api_key"),
    }
end

function KOFever:showMessage(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

--- Shows a progress message, replacing the previous one, and paints it right away
-- because the sync blocks the UI loop.
function KOFever:showProgress(text)
    self:closeProgress()
    self.progress_message = InfoMessage:new{ text = text }
    UIManager:show(self.progress_message)
    UIManager:forceRePaint()
end

function KOFever:closeProgress()
    if self.progress_message then
        UIManager:close(self.progress_message)
        self.progress_message = nil
    end
end

-- Login ----------------------------------------------------------------------

function KOFever:showLoginDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("KOFever server login"),
        fields = {
            {
                text = self.settings:readSetting("server") or "",
                hint = _("Server URL, e.g. https://rss.example.com"),
            },
            {
                text = "",
                hint = _("Username"),
            },
            {
                text = "",
                hint = _("API password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        if self:saveLogin(fields[1], fields[2], fields[3]) then
                            UIManager:close(dialog)
                            self:verifyLogin()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Validates and stores the login. Only the hashed API key is stored.
-- @treturn bool true if the login was saved
function KOFever:saveLogin(server, username, api_password)
    server = util.trim(server or "")
    username = util.trim(username or "")
    api_password = api_password or ""
    if server == "" or username == "" or api_password == "" then
        self:showMessage(_("Please fill in the server URL, username and API password."))
        return false
    end

    -- Accept a pasted endpoint URL, and default to HTTPS when no scheme is given.
    server = server:gsub("/+$", ""):gsub("/api/fever%.php.*$", ""):gsub("/+$", "")
    if not server:match("^%a[%w+.-]*://") then
        server = "https://" .. server
    end
    if not server:match("^https://") then
        self:showMessage(_("The server URL must start with https://"))
        return false
    end

    -- Cached articles and queued reads belong to the previous server, so drop them.
    local old_server = self.settings:readSetting("server")
    if old_server and old_server ~= "" and old_server ~= server then
        getStore():clear()
        logger.info("KOFever: server changed, local cache cleared")
    end

    self.settings:saveSetting("server", server)
    self.settings:saveSetting("api_key", FeverClient.makeApiKey(username, api_password))
    self.settings:flush()
    return true
end

function KOFever:verifyLogin()
    if not NetworkMgr:isOnline() then
        self:showMessage(_("Login saved. It will be checked at the next sync."))
        return
    end
    self:showProgress(_("Checking login…"))
    local call_ok, ok, err = pcall(function()
        return self:getClient():checkAuth()
    end)
    self:closeProgress()
    if not call_ok then
        logger.err("KOFever: login check failed:", ok)
        self:showMessage(_("Login saved, but the check failed unexpectedly. See the log for details."))
    elseif ok then
        self:showMessage(_("Login saved and accepted by the server."), 3)
    else
        self:showMessage(_("Login saved, but it could not be confirmed:") .. "\n" .. errorMessage(err))
    end
end

-- Sync -----------------------------------------------------------------------

function KOFever:syncNow()
    if not self:isConfigured() then
        self:showMessage(_("Set up the server first with KOFever > Server login."))
        return
    end
    NetworkMgr:runWhenOnline(function()
        self:runSync()
    end)
end

function KOFever:runSync()
    self:showProgress(_("Syncing…"))
    local progress = function(stage, current, total)
        if stage == "push" then
            self:showProgress(T(_("Sending read articles: %1 of %2"), current, total))
        elseif stage == "feeds" then
            self:showProgress(_("Fetching feed names…"))
        elseif stage == "unread" then
            self:showProgress(_("Fetching unread list…"))
        elseif stage == "items" then
            self:showProgress(T(_("Downloading articles: batch %1 of %2"), current, total))
        end
    end

    local call_ok, finished, summary, err = pcall(FeverSync.run, self:getClient(), getStore(), {
        max_items = MAX_CACHED_ITEMS,
        html = FeverHtml,
        progress = progress,
    })
    self:closeProgress()

    if not call_ok then
        logger.err("KOFever: sync raised an error:", finished)
        -- Reload the cache from disk so in-memory changes from the failed step are dropped.
        getStore():load()
        self:showMessage(_("Sync failed unexpectedly. See the log for details."))
        return
    end
    if not finished then
        self:showMessage(_("Sync failed.") .. "\n" .. errorMessage(err))
        return
    end

    local lines = {
        _("Sync complete."),
        T(_("New articles: %1"), summary.new),
        T(_("Reads sent: %1"), summary.pushed),
        T(_("Failed batches: %1"), summary.failed_batches),
    }
    if summary.push_failed > 0 then
        table.insert(lines, T(_("Reads still waiting to be sent: %1"), summary.push_failed))
    end
    if summary.not_downloaded > 0 then
        table.insert(lines, T(_("Not downloaded (cache limit): %1"), summary.not_downloaded))
    end
    if summary.feeds_failed then
        table.insert(lines, _("Feed names could not be refreshed."))
    end
    logger.info("KOFever: sync summary", summary)
    self:showMessage(table.concat(lines, "\n"))
end

-- Reading --------------------------------------------------------------------

function KOFever:showArticleList()
    local store = getStore()
    local items = store:getSortedItems(SHOW_OPENED_ARTICLES)
    local menu
    local item_table = {}
    for _, item in ipairs(items) do
        local feed_title = store:getFeedTitle(item.feed_id)
        local article_id = item.id
        table.insert(item_table, {
            text = item.read and T(_("(read) %1"), item.title) or item.title,
            mandatory = feed_title and shorten(feed_title, MAX_FEED_TITLE_CHARS) or nil,
            callback = function()
                UIManager:close(menu)
                self:openArticle(article_id)
            end,
        })
    end
    if #item_table == 0 then
        table.insert(item_table, {
            text = _("No unread articles. Run Sync now."),
            select_enabled = false,
        })
    end

    menu = Menu:new{
        title = _("Unread articles"),
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    }
    UIManager:show(menu)
end

function KOFever:openArticle(id)
    local store = getStore()
    local item = store:getItem(id)
    if not item then
        self:showMessage(_("This article is no longer in the cache. Run Sync now."))
        return
    end
    store:markOpened(id)

    local parts = { store:getFeedTitle(item.feed_id) or _("Unknown feed"), "" }
    if item.url then
        table.insert(parts, item.url)
        table.insert(parts, "")
    end
    table.insert(parts, item.text ~= "" and item.text or _("(This article has no text.)"))

    UIManager:show(TextViewer:new{
        title = item.title,
        title_multilines = true,
        text = table.concat(parts, "\n"),
        text_type = "general",
    })
end

return KOFever
