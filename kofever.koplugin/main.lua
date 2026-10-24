--[[--
KOFever: read FreshRSS articles offline through the Fever or Google Reader API.

Syncs unread articles to a local cache, shows them as plain text, and queues reads
made offline so they are marked read on the server at the next sync.

@module koplugin.kofever
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

-- The plugin directory is only on package.path while main.lua is loading,
-- so the plugin's own modules must be required here at the top.
local FeverClient = require("kofever_client")
local GReaderClient = require("kofever_greader_client")
local FeverHtml = require("kofever_html")
local FeverStore = require("kofever_store")
local FeverSync = require("kofever_sync")

-- Number of articles kept in the local cache: user selectable within these bounds.
local DEFAULT_CACHE_SIZE = 200
local MIN_CACHE_SIZE = 50
local MAX_CACHE_SIZE = 3000
local CACHE_SIZE_STEP = 50

local SETTINGS_FILE = "kofever_settings.lua"
local CACHE_FILE = "kofever_cache.lua"
local TEXT_DIR = "kofever_articles"

-- Shared by every plugin instance (file manager and reader), loaded on first use.
local shared_store

local function getStore()
    if not shared_store then
        shared_store = FeverStore:new{
            file = DataStorage:getSettingsDir() .. "/" .. CACHE_FILE,
            text_dir = DataStorage:getSettingsDir() .. "/" .. TEXT_DIR,
        }
    end
    return shared_store
end

-- FreshRSS's Fever API swaps these for full-width look-alikes (see escapeToUnicodeAlternative in
-- FreshRSS), which some e-reader fonts render poorly. Show the plain characters instead.
local FULLWIDTH_TO_ASCII = {
    ["\239\188\134"] = "&", -- U+FF06
    ["\239\188\156"] = "<", -- U+FF1C
    ["\239\188\158"] = ">", -- U+FF1E
}

local function displayTitle(text)
    if not text then
        return nil
    end
    return (text:gsub("\239\188[\134\156\158]", FULLWIDTH_TO_ASCII))
end

-- Supported server APIs. The names are product names, so they are not translated.
local API_FEVER = "fever"
local API_GREADER = "greader"
local API_NAMES = { [API_FEVER] = "Fever", [API_GREADER] = "Google Reader" }

local function errorMessage(err)
    local kind = err and err.kind
    if kind == "auth" then
        return _("The server rejected the login. Check the username and API password.")
    elseif kind == "http" then
        return T(_("The server returned an error (%1). Check the server URL."), err.detail)
    elseif kind == "json" then
        return _("The server sent an unexpected response. Check the server URL, the API type and that API access is enabled in FreshRSS.")
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
                text_func = function()
                    return self:showReadArticles() and _("Browse articles") or _("Browse unread articles")
                end,
                callback = function()
                    self:showArticleList()
                end,
            },
            {
                text = _("Show read articles"),
                help_text = _([[Keep read articles in the list, with unread titles in bold and read titles in normal weight. Read articles stay cached until the cache limit removes them, oldest first.

When off, articles disappear from the list once opened and are removed from the cache once the server confirms they are read.]]),
                checked_func = function()
                    return self:showReadArticles()
                end,
                callback = function()
                    self.settings:saveSetting("show_read_articles", not self:showReadArticles())
                    self.settings:flush()
                end,
            },
            {
                text_func = function()
                    return T(_("Cache size: %1 articles"), self:getCacheSize())
                end,
                help_text = _("The maximum number of articles kept on the device. When there are more unread articles on the server, the newest are downloaded. Reducing the size removes read articles first, then the oldest unread ones."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showCacheSizeDialog(touchmenu_instance)
                end,
            },
            {
                text = _("Clear cache"),
                help_text = _("Deletes every downloaded article and any reads not yet sent to the server. Nothing is changed on the server. Your login and settings are kept."),
                keep_menu_open = true,
                callback = function()
                    self:confirmClearCache()
                end,
            },
            {
                text = _("Server login"),
                keep_menu_open = true,
                callback = function()
                    self:showApiChoice()
                end,
            },
        },
    }
end

function KOFever:getApiType()
    return self.settings:readSetting("api_type") or API_FEVER
end

local function isSet(value)
    return value ~= nil and value ~= ""
end

function KOFever:isConfigured()
    if not isSet(self.settings:readSetting("server")) then
        return false
    end
    if self:getApiType() == API_GREADER then
        return isSet(self.settings:readSetting("greader_url")) and isSet(self.settings:readSetting("greader_auth"))
    end
    return isSet(self.settings:readSetting("api_key"))
end

function KOFever:getCacheSize()
    return self.settings:readSetting("cache_size") or DEFAULT_CACHE_SIZE
end

function KOFever:showCacheSizeDialog(touchmenu_instance)
    UIManager:show(SpinWidget:new{
        title_text = _("Cache size"),
        info_text = _("Maximum number of articles kept on the device."),
        value = self:getCacheSize(),
        value_min = MIN_CACHE_SIZE,
        value_max = MAX_CACHE_SIZE,
        value_step = CACHE_SIZE_STEP,
        value_hold_step = CACHE_SIZE_STEP * 10,
        default_value = DEFAULT_CACHE_SIZE,
        callback = function(spin)
            self.settings:saveSetting("cache_size", spin.value)
            self.settings:flush()
            -- Apply a smaller limit straight away so the space is freed now.
            local store = getStore()
            if store:applyLimit(spin.value) > 0 then
                store:save()
            end
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    })
end

function KOFever:confirmClearCache()
    local store = getStore()
    local text = T(_("Delete all %1 downloaded articles from this device?\n\nNothing is changed on the server. Run Sync now to download unread articles again."), store:itemCount())
    local pending = #store:getPendingReads()
    if pending > 0 then
        text = text .. "\n\n" .. T(_("%1 read articles have not been sent to the server yet. They will stay unread on the server."), pending)
    end
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Clear cache"),
        ok_callback = function()
            store:clear()
            logger.info("KOFever: cache cleared by user")
            self:showMessage(_("Cache cleared."), 3)
        end,
    })
end

function KOFever:showReadArticles()
    return self.settings:isTrue("show_read_articles")
end

function KOFever:getClient()
    if self:getApiType() == API_GREADER then
        return GReaderClient:new{
            base_url = self.settings:readSetting("greader_url"),
            auth = self.settings:readSetting("greader_auth"),
        }
    end
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

--- Asks which API the server uses, then shows the login dialog for it.
function KOFever:showApiChoice()
    local current = self.settings:readSetting("server") and self:getApiType()
    local dialog
    local function choice(api_type)
        local label = T(_("%1 API"), API_NAMES[api_type])
        if api_type == current then
            label = T(_("%1 (current)"), label)
        end
        return {
            {
                text = label,
                callback = function()
                    UIManager:close(dialog)
                    self:showLoginDialog(api_type)
                end,
            },
        }
    end
    dialog = ButtonDialog:new{
        title = _("Which API does your server use?\n\nFreshRSS supports both. Google Reader sends read articles in batches; Fever works with more older servers."),
        buttons = {
            choice(API_FEVER),
            choice(API_GREADER),
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function KOFever:showLoginDialog(api_type)
    local dialog
    dialog = MultiInputDialog:new{
        title = T(_("Server login (%1 API)"), API_NAMES[api_type]),
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
                        local server, username, api_password = self:checkLoginFields(fields[1], fields[2], fields[3])
                        if not server then
                            return
                        end
                        UIManager:close(dialog)
                        if api_type == API_GREADER then
                            self:loginGReader(server, username, api_password)
                        else
                            self:saveFeverLogin(server, username, api_password)
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

--- Validates the login fields and normalises the server URL.
-- @treturn string|nil server URL, or nil after showing a message
-- @treturn string username
-- @treturn string API password
function KOFever:checkLoginFields(server, username, api_password)
    server = util.trim(server or "")
    username = util.trim(username or "")
    api_password = api_password or ""
    if server == "" or username == "" or api_password == "" then
        self:showMessage(_("Please fill in the server URL, username and API password."))
        return nil
    end

    -- Accept a pasted endpoint URL, and default to HTTPS when no scheme is given.
    server = server:gsub("/+$", ""):gsub("/api/fever%.php.*$", ""):gsub("/api/greader%.php.*$", ""):gsub("/+$", "")
    if not server:match("^%a[%w+.-]*://") then
        server = "https://" .. server
    end
    if not server:match("^https?://[^/]") then
        self:showMessage(_("The server URL must start with https:// or http://"))
        return nil
    end
    return server, username, api_password
end

--- Identifies the account without storing the username: an MD5 hash of it, lowercased.
local function accountId(username)
    return md5(username:lower())
end

--- Clears the cache when the server, the API or the user changes: cached article IDs and queued
-- reads belong to the previous account. Settings saved before the account hash existed have
-- none, so only the server and API are compared for them.
function KOFever:resetCacheIfAccountChanged(server, api_type, account)
    local old_server = self.settings:readSetting("server")
    local old_account = self.settings:readSetting("account")
    if isSet(old_server) and (old_server ~= server or self:getApiType() ~= api_type
            or (isSet(old_account) and old_account ~= account)) then
        getStore():clear()
        logger.info("KOFever: server, API or user changed, local cache cleared")
    end
end

--- Stores a Fever login. Only the hashed API key is stored.
function KOFever:saveFeverLogin(server, username, api_password)
    local account = accountId(username)
    self:resetCacheIfAccountChanged(server, API_FEVER, account)
    self.settings:saveSetting("account", account)
    self.settings:saveSetting("api_type", API_FEVER)
    self.settings:saveSetting("server", server)
    self.settings:saveSetting("api_key", FeverClient.makeApiKey(username, api_password))
    self.settings:delSetting("greader_url")
    self.settings:delSetting("greader_auth")
    self.settings:flush()
end

local function plainHttpNote(server)
    if server:match("^http://") then
        return "\n\n" .. _("Note: this server uses plain http, so the login and articles are sent unencrypted.")
    end
    return ""
end

--- Logs in with the Google Reader API and stores the returned auth token.
-- The password is only used for this request and is never stored, so this needs a connection.
function KOFever:loginGReader(server, username, api_password)
    NetworkMgr:runWhenOnline(function()
        self:showProgress(_("Logging in…"))
        local call_ok, ok, base_url, auth = pcall(GReaderClient.findEndpoint, server, username, api_password)
        -- Logging in does not use the Authorization header, but every later call does, and some web
        -- servers (Apache without extra configuration) drop it. Make one authorised call to be sure.
        local check_ok, check_err = true, nil
        if call_ok and ok then
            local pcall_ok, result, err = pcall(function()
                return GReaderClient:new{ base_url = base_url, auth = auth }:checkAuth()
            end)
            if pcall_ok then
                check_ok, check_err = result, err
            else
                call_ok, ok = false, result
            end
        end
        self:closeProgress()
        if not call_ok then
            logger.err("KOFever: Google Reader login failed:", ok)
            self:showMessage(_("Login failed unexpectedly. See the log for details."))
            return
        end
        if not ok then
            self:showMessage(_("Login failed:") .. "\n" .. errorMessage(base_url))
            return
        end
        if not check_ok then
            local hint = ""
            if check_err and check_err.kind == "auth" then
                hint = "\n\n" .. _("The password was accepted, but later requests were refused. The web server may be dropping the Authorization header; see the FreshRSS documentation on API access.")
            end
            self:showMessage(_("Login failed:") .. "\n" .. errorMessage(check_err) .. hint)
            return
        end
        local account = accountId(username)
        self:resetCacheIfAccountChanged(server, API_GREADER, account)
        self.settings:saveSetting("account", account)
        self.settings:saveSetting("api_type", API_GREADER)
        self.settings:saveSetting("server", server)
        self.settings:saveSetting("greader_url", base_url)
        self.settings:saveSetting("greader_auth", auth)
        self.settings:delSetting("api_key")
        self.settings:flush()
        local note = plainHttpNote(server)
        self:showMessage(_("Logged in with the Google Reader API.") .. note, note == "" and 3 or nil)
    end)
end

function KOFever:verifyLogin()
    local note = plainHttpNote(self.settings:readSetting("server"))
    if not NetworkMgr:isOnline() then
        self:showMessage(_("Login saved. It will be checked at the next sync.") .. note)
        return
    end
    self:showProgress(_("Checking login…"))
    local call_ok, ok, err = pcall(function()
        return self:getClient():checkAuth()
    end)
    self:closeProgress()
    if not call_ok then
        logger.err("KOFever: login check failed:", ok)
        self:showMessage(_("Login saved, but the check failed unexpectedly. See the log for details.") .. note)
    elseif ok then
        self:showMessage(_("Login saved and accepted by the server.") .. note, note == "" and 3 or nil)
    else
        self:showMessage(_("Login saved, but it could not be confirmed:") .. "\n" .. errorMessage(err) .. note)
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
        max_items = self:getCacheSize(),
        keep_read = self:showReadArticles(),
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

--- Shows cached articles. When they span more than one category, a category list comes first,
-- with an "All articles" entry; tapping a category shows its articles and the back arrow returns.
-- The list stays open under an opened article and is refreshed when the article is closed.
function KOFever:showArticleList()
    local store = getStore()
    local show_read = self:showReadArticles()
    local categories_title = _("Categories")
    local menu
    -- Key of the article list being shown, nil for the category list. Keys are "all", "uncategorised"
    -- or "group:<id>"; the prefix keeps a category named "all" from colliding with the reserved keys.
    local current_key
    local views, category_table, refresh

    local function countUnread(items)
        local unread = 0
        for _, item in ipairs(items) do
            if not item.read then
                unread = unread + 1
            end
        end
        return unread
    end

    local function articlesTitle(name, unread)
        return show_read and T(_("%1 (%2 unread)"), name, unread) or name
    end

    local function articleTable(items)
        local item_table = {}
        for index, item in ipairs(items) do
            table.insert(item_table, {
                text = displayTitle(item.title),
                -- With read articles shown, unread titles are bold and read titles normal weight.
                bold = show_read and not item.read,
                mandatory = displayTitle(store:getFeedTitle(item.feed_id)),
                callback = function()
                    -- Previous and Next in the viewer step through this list as it is now.
                    self:openArticle(items, index, function(last_index)
                        refresh(items, last_index)
                    end)
                end,
            })
        end
        if #item_table == 0 then
            table.insert(item_table, {
                text = show_read and _("No articles. Run Sync now.") or _("No unread articles. Run Sync now."),
                select_enabled = false,
            })
        end
        return item_table
    end

    -- (Re)reads the cache into `views` (one per article list) and `category_table`.
    local function build()
        local all_items = store:getSortedItems(show_read)
        views = { all = { name = _("All articles"), items = all_items, unread = countUnread(all_items) } }
        category_table = {}
        local function addCategory(key, name, items, unread)
            local index = #category_table + 1
            views[key] = { name = name, items = items, unread = unread }
            table.insert(category_table, {
                text = name,
                bold = show_read and unread > 0,
                mandatory = tostring(unread),
                callback = function()
                    -- Remember where we were so the back arrow can return to it.
                    table.insert(menu.paths, { index = index, name = name })
                    current_key = key
                    menu:switchItemTable(articlesTitle(name, unread), articleTable(items))
                end,
            })
        end
        addCategory("all", views.all.name, all_items, views.all.unread)
        for _, category in ipairs(store:getCategories(show_read)) do
            local name = displayTitle(category.title)
            if not category.id then
                name = _("Uncategorised")
            elseif not name or name == "" then
                name = T(_("Category %1"), category.id)
            end
            addCategory(category.id and ("group:" .. category.id) or "uncategorised", name, category.items, category.unread)
        end
    end

    build()
    -- With one category or none (e.g. before the first sync that fetched categories), skip the category list.
    local use_categories = #category_table > 2

    --- Rebuilds the current article list after reading. `snapshot` is the list the article was opened
    -- from and `last_index` the position in it of the last article viewed.
    refresh = function(snapshot, last_index)
        build()
        local view
        if use_categories then
            local path = menu.paths[#menu.paths]
            -- A category emptied by reading its last article is shown empty rather than vanishing.
            view = views[current_key] or { name = path and path.name or "", items = {}, unread = 0 }
        else
            view = views.all
            view.name = show_read and _("Articles") or _("Unread articles")
        end
        -- Stay on the last article viewed, or on the next one still listed if it is now hidden.
        local positions = {}
        for i, item in ipairs(view.items) do
            positions[item.id] = i
        end
        local position
        for k = last_index, #snapshot do
            position = positions[snapshot[k].id]
            if position then
                break
            end
        end
        if not position and #view.items > 0 then
            position = #view.items
        end
        menu:switchItemTable(articlesTitle(view.name, view.unread), articleTable(view.items), position)
    end

    local menu_options = {
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    }

    if not use_categories then
        menu_options.title = articlesTitle(show_read and _("Articles") or _("Unread articles"), views.all.unread)
        menu_options.item_table = articleTable(views.all.items)
        menu = Menu:new(menu_options)
        UIManager:show(menu)
        return
    end

    menu_options.title = categories_title
    menu_options.item_table = category_table
    menu_options.onReturn = function()
        local path = table.remove(menu.paths)
        if path then
            current_key = nil
            -- Rebuild so the unread counts include articles read in the meantime.
            build()
            menu:switchItemTable(categories_title, category_table, path.index)
        end
    end
    -- The close button and the Back key go up to the category list before closing.
    menu_options.onClose = function(menu_self)
        if #menu_self.paths > 0 then
            menu_self:onReturn()
            return true
        end
        return Menu.onClose(menu_self)
    end
    menu = Menu:new(menu_options)
    UIManager:show(menu)
end

--- Opens `items[index]` in a TextViewer, with Previous and Next buttons that step through `items`.
-- @func[opt] close_callback called with the index of the last article viewed when reading stops
-- (the viewer is closed, or an article could not be opened)
function KOFever:openArticle(items, index, close_callback)
    local store = getStore()
    local id = items[index].id
    local function done()
        if close_callback then close_callback(index) end
    end
    local item = store:getItem(id)
    if not item then
        self:showMessage(_("This article is no longer in the cache. Run Sync now."))
        done()
        return
    end
    local text = store:getText(id)
    if not text then
        -- The text file is gone, so drop the entry: the next sync downloads it again if it is still unread.
        logger.warn("KOFever: text file missing for article", id)
        store:removeItem(id)
        store:save()
        self:showMessage(_("This article's text is missing from the cache. Run Sync now to download it again."))
        done()
        return
    end
    store:markOpened(id)

    local parts = { displayTitle(store:getFeedTitle(item.feed_id)) or _("Unknown feed"), "" }
    if item.url then
        table.insert(parts, item.url)
        table.insert(parts, "")
    end
    table.insert(parts, text ~= "" and text or _("(This article has no text.)"))

    local viewer
    local function step(offset)
        -- Close directly rather than through onClose, so the list is only rebuilt when reading stops.
        UIManager:close(viewer)
        self:openArticle(items, index + offset, close_callback)
    end
    viewer = TextViewer:new{
        title = displayTitle(item.title),
        title_multilines = true,
        text = table.concat(parts, "\n"),
        text_type = "general",
        buttons_table = {
            {
                {
                    text = "◁ " .. _("Previous"),
                    enabled = index > 1,
                    callback = function()
                        step(-1)
                    end,
                },
                {
                    text = T(_("%1 of %2"), index, #items),
                    enabled = false,
                },
                {
                    text = _("Next") .. " ▷",
                    enabled = index < #items,
                    callback = function()
                        step(1)
                    end,
                },
            },
        },
        -- Keep TextViewer's own Find, top, bottom and Close buttons below ours.
        add_default_buttons = true,
        close_callback = done,
    }
    UIManager:show(viewer)
end

return KOFever
