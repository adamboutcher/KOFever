-- Offline test harness: stubs KOReader modules and simulates a FreshRSS Fever endpoint.
--
-- Run from the repository root:
--   KOREADER_BASE=/path/to/koreader-base luajit tests/run_tests.lua
--
-- Needs LuaJIT, dkjson (e.g. the lua-dkjson package) and a checkout of
-- koreader-base for ffi/sha2.lua. KOREADER_BASE defaults to ../koreader-base.
local base = os.getenv("KOREADER_BASE") or "../koreader-base"
package.path = "kofever.koplugin/?.lua;" .. base .. "/?.lua;/usr/share/lua/5.1/?.lua;" .. package.path

local dkjson = require("dkjson")
local sha2 = require("ffi/sha2")

local function pass(name, cond)
    print((cond and "PASS " or "FAIL ") .. name)
    if not cond then os.exit(1) end
end

package.preload["logger"] = function()
    local quiet = function() end
    return { dbg = quiet, info = quiet, warn = quiet, err = quiet }
end
package.preload["rapidjson"] = function()
    return { decode = function(s) return dkjson.decode(s) end }
end
package.preload["ltn12"] = function()
    return { source = { string = function(s) local done = false
        return function() if done then return nil end done = true return s end end } }
end
package.preload["socket"] = function()
    return { skip = function(n, ...) return select(n + 1, ...) end }
end
package.preload["socketutil"] = function()
    return {
        LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30, FILE_BLOCK_TIMEOUT = 15, FILE_TOTAL_TIMEOUT = 60,
        set_timeout = function(_, b, t) return b, t end,
        reset_timeout = function() end,
        table_sink = function(t) return function(chunk) if chunk then table.insert(t, chunk) end return 1 end, t end,
        describe_error = function(code) return "described " .. tostring(code) end,
    }
end

-- In-memory LuaSettings with a fake disk, so reloads can be tested.
local disk = {}
local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local c = {} for k, x in pairs(v) do c[k] = deepcopy(x) end return c
end
-- Article text files go in a fresh temporary directory.
local TMP = os.tmpname()
os.remove(TMP)
os.execute("mkdir -p '" .. TMP .. "'")
local function textDir(name) return TMP .. "/" .. name end
local function fileExists(path) local f = io.open(path, "rb") if f then f:close() return true end return false end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, what)
            assert(what == "mode")
            if os.execute("test -d '" .. path .. "'") == 0 then return "directory" end
            return fileExists(path) and "file" or nil
        end,
        mkdir = function(path) return os.execute("mkdir '" .. path .. "'") == 0 end,
        dir = function(path)
            local names = { ".", ".." }
            local p = io.popen("ls -1 '" .. path .. "'")
            for name in p:lines() do table.insert(names, name) end
            p:close()
            local i = 0
            return function() i = i + 1 return names[i] end
        end,
    }
end

package.preload["luasettings"] = function()
    local LS = {}
    LS.__index = LS
    function LS:open(file) return setmetatable({ file = file, data = deepcopy(disk[file]) or {} }, LS) end
    function LS:readSetting(k, d) if d and self.data[k] == nil then self.data[k] = d end return self.data[k] end
    function LS:saveSetting(k, v) self.data[k] = v end
    function LS:flush() disk[self.file] = deepcopy(self.data) end
    return LS
end

-- Fake FreshRSS server.
local server = { online = true, key = sha2.md5("alice:secret"), calls = {}, unread = {}, items = {} }
local BASE_ID = 1700000000000000
for i = 1, 130 do
    local id = string.format("%.0f", BASE_ID + i)
    server.items[id] = { id = id, feed_id = (i % 3) + 1, title = "Article &amp; " .. i,
        html = "<p>Body <b>" .. i .. "</b></p>", url = "https://example.com/" .. i,
        is_read = 0, created_on_time = 1700000000 + i }
    server.unread[id] = true
end

local function parse(str, into)
    for pair in (str or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]+)=?(.*)$")
        into[k] = v
    end
end

-- Google Reader side of the fake server, mirroring FreshRSS's p/api/greader.php.
-- FreshRSS answers at <server>/api/greader.php; "mini.example.com" stands in for servers
-- that answer at their root URL.
local GREADER_BASES = { ["https://rss.example.com/api/greader.php"] = true, ["https://mini.example.com"] = true }
local GREADER_USER, GREADER_PASS = "alice", "s3cr&t=x +"
local GREADER_AUTH, GREADER_TOKEN = "alice/0123abcd", "tokenZZZZ"
server.greader_calls = {}

local function urlDecode(str)
    return (str:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Parses a query string or form body into key -> list of values.
local function parseMulti(str)
    local out = {}
    for pair in (str or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]+)=?(.*)$")
        k, v = urlDecode(k), urlDecode(v)
        out[k] = out[k] or {}
        table.insert(out[k], v)
    end
    return out
end

local function sortedUnreadDesc()
    local ids = {}
    for id in pairs(server.unread) do table.insert(ids, id) end
    table.sort(ids, function(a, b) return a > b end)
    return ids
end

local function greaderHandler(req, path)
    local query = parseMulti(req.url:match("%?(.*)$"))
    local form = parseMulti(req.source and req.source() or "")
    table.insert(server.greader_calls, { path = path, query = query, form = form })
    local function one(t, k) return t[k] and t[k][1] end
    if path == "/accounts/ClientLogin" then
        if one(form, "Email") == GREADER_USER and one(form, "Passwd") == GREADER_PASS then
            return 200, "SID=" .. GREADER_AUTH .. "\nLSID=null\nAuth=" .. GREADER_AUTH .. "\n"
        end
        return 401, "Unauthorized"
    end
    if (req.headers or {})["Authorization"] ~= "GoogleLogin auth=" .. GREADER_AUTH then
        return 401, "Unauthorized"
    end
    if path == "/reader/api/0/token" then
        return 200, GREADER_TOKEN .. "\n"
    elseif path == "/reader/api/0/subscription/list" then
        return 200, dkjson.encode{ subscriptions = {
            { id = "feed/1", title = "Feed One", categories = { { id = "user/-/label/Tech", label = "Tech" } } },
            { id = "feed/2", title = "Feed Two", categories = {
                { id = "user/-/label/Tech", label = "Tech" }, { id = "user/-/label/News", label = "News" } } },
            { id = "feed/3", title = "Feed Three", categories = {} },
        } }
    elseif path == "/reader/api/0/stream/items/ids" then
        assert(one(query, "s") == "user/-/state/com.google/reading-list")
        assert(one(query, "xt") == "user/-/state/com.google/read")
        local n, c = tonumber(one(query, "n")), one(query, "c")
        local refs, last = {}, nil
        for _, id in ipairs(sortedUnreadDesc()) do
            if (not c or id < c) and #refs < n then
                table.insert(refs, { id = id })
                last = id
            end
        end
        return 200, dkjson.encode{ itemRefs = refs, continuation = (#refs >= n) and last or nil }
    elseif path == "/reader/api/0/stream/items/contents" then
        local items = {}
        for _, id in ipairs(form.i or {}) do
            local it = server.items[id]
            if it then
                local categories = { "user/-/state/com.google/reading-list" }
                if not server.unread[id] then
                    table.insert(categories, "user/-/state/com.google/read")
                end
                table.insert(items, {
                    id = "tag:google.com,2005:reader/item/" .. string.format("%016x", tonumber(id)),
                    title = it.title, published = it.created_on_time,
                    canonical = { { href = it.url } }, summary = { content = it.html },
                    origin = { streamId = "feed/" .. it.feed_id }, categories = categories,
                })
            end
        end
        return 200, dkjson.encode{ id = "user/-/state/com.google/reading-list", items = items }
    elseif path == "/reader/api/0/edit-tag" then
        if one(form, "T") ~= GREADER_TOKEN then
            return 401, "Unauthorized"
        end
        if one(form, "a") == "user/-/state/com.google/read" then
            for _, id in ipairs(form.i or {}) do server.unread[id] = nil end
        end
        return 200, "OK"
    end
    return 404, "Not Found"
end

package.preload["socket.http"] = function()
    return { request = function(req)
        if not server.online then return nil, "timeout" end
        if not req.url:find("/api/fever.php", 1, true) then
            local status, body = 404, "Not Found"
            for greader_base in pairs(GREADER_BASES) do
                if req.url:sub(1, #greader_base) == greader_base then
                    local path = req.url:sub(#greader_base + 1):gsub("%?.*$", "")
                    status, body = greaderHandler(req, path)
                end
            end
            req.sink(body)
            req.sink(nil)
            return 1, status, {}, "HTTP/1.1 " .. status
        end
        local params = {}
        parse(req.url:match("%?(.*)$"), params)
        local body = req.source()
        parse(body, params)
        table.insert(server.calls, params)
        local resp = { api_version = 3, auth = 0 }
        if params.api_key == server.key then
            resp.auth = 1
            resp.last_refreshed_on_time = 0
            if params.groups then
                resp.groups = { { id = 10, title = "Tech" }, { id = 20, title = "News" } }
            end
            if params.feeds then
                resp.feeds = { { id = 1, title = "Feed One" }, { id = 2, title = "Feed Two" }, { id = 3, title = "Feed Three" } }
            end
            if params.groups or params.feeds then
                -- Feed 3 has no category; as in FreshRSS, feeds_groups comes with both flags.
                resp.feeds_groups = { { group_id = 10, feed_ids = "1,2" }, { group_id = 20, feed_ids = "2" } }
            end
            if params.unread_item_ids then
                local ids = {}
                for id in pairs(server.unread) do table.insert(ids, id) end
                table.sort(ids)
                resp.unread_item_ids = table.concat(ids, ",")
            end
            if params.items then
                resp.items = {}
                local n = 0
                for id in (params.with_ids or ""):gmatch("%d+") do
                    n = n + 1
                    if n > 50 then break end -- FreshRSS LIMIT 50
                    local it = server.items[id]
                    if it then
                        local copy = deepcopy(it)
                        copy.is_read = server.unread[id] and 0 or 1
                        table.insert(resp.items, copy)
                    end
                end
            end
            if params.mark == "item" and params.as == "read" and params.id then
                server.unread[params.id] = nil
            end
        end
        local sink = req.sink
        sink(dkjson.encode(resp))
        sink(nil)
        return 1, 200, {}, "HTTP/1.1 200 OK"
    end }
end

local FeverClient = require("kofever_client")
local FeverHtml = require("kofever_html")
local FeverStore = require("kofever_store")
local FeverSync = require("kofever_sync")

local MAX = 100
local function newStore() return FeverStore:new{ file = "cache", text_dir = textDir("cache") } end
local function sync(client, store)
    return FeverSync.run(client, store, { max_items = MAX, html = FeverHtml })
end
local function countUnread() local n = 0 for _ in pairs(server.unread) do n = n + 1 end return n end

pass("md5 key matches md5sum", FeverClient.makeApiKey("user", "apipass") == "559fb1c1cc2dd82e531b5e48573fa62d")
pass("idToString avoids exponent", FeverClient.idToString(1700000000000123) == "1700000000000123")

-- Wrong key
local bad = FeverClient:new{ server = "https://rss.example.com", api_key = FeverClient.makeApiKey("alice", "wrong") }
local store = newStore()
local ok, summary, err, _
ok, _, err = sync(bad, store)
pass("wrong key aborts", not ok and err.kind == "auth" and store:itemCount() == 0)
pass("api_key sent in POST body", server.calls[#server.calls].api_key ~= nil)

-- First sync
local client = FeverClient:new{ server = "https://rss.example.com", api_key = server.key }
server.calls = {}
ok, summary = sync(client, store)
pass("first sync ok", ok)
pass("fetched newest 100 in 2 batches", summary.new == 100 and #server.calls == 4)
pass("30 not downloaded", summary.not_downloaded == 30)
pass("newest article cached", store:getItem(string.format("%.0f", BASE_ID + 130)) ~= nil)
pass("oldest article not cached", store:getItem(string.format("%.0f", BASE_ID + 1)) == nil)
local first = store:getSortedItems(false)[1]
pass("sorted newest first", first.created == 1700000000 + 130)
pass("title entities decoded", first.title == "Article & 130")
pass("html converted", store:getText(first.id) == "Body 130")
pass("text kept out of the index", disk["cache"].items[first.id].text == nil and first.text == nil)
pass("feed title stored", store:getFeedTitle(first.feed_id) == "Feed Two")

-- Read three articles offline
local opened = {}
for i = 1, 3 do
    local item = store:getSortedItems(false)[1]
    store:markOpened(item.id)
    table.insert(opened, item.id)
end
pass("opened articles hidden", #store:getSortedItems(false) == 97)
pass("opened articles still readable", store:getText(opened[1]) ~= "")
pass("three pending reads", #store:getPendingReads() == 3)

-- Reload from disk (simulates restarting KOReader)
store = newStore()
pass("pending reads persisted", #store:getPendingReads() == 3 and store:getItem(opened[1]).read == true)

-- Sync with the network down
server.online = false
ok, _, err = sync(client, store)
pass("offline sync aborts with network error", not ok and err.kind == "network")
pass("cache intact after failed sync", store:itemCount() == 100 and #store:getPendingReads() == 3)
store = newStore()
pass("disk intact after failed sync", store:itemCount() == 100 and #store:getPendingReads() == 3)

-- Back online
server.online = true
ok, summary = sync(client, store)
pass("online sync ok", ok)
pass("three reads pushed", summary.pushed == 3 and #store:getPendingReads() == 0)
pass("server marked them read", not server.unread[opened[1]] and countUnread() == 127)
pass("opened articles pruned", store:getItem(opened[1]) == nil and summary.removed == 3)
pass("cache back to limit, no wasted downloads", store:itemCount() == MAX and summary.new == 3 and summary.dropped == 0)

-- Marked read in web interface
local victim = store:getSortedItems(false)[5].id
server.unread[victim] = nil
ok = sync(client, store)
pass("web-read article pruned", ok and store:getItem(victim) == nil)

-- Pending reads never dropped by the cache limit
local oldest = store:getSortedItems(false)
oldest = oldest[#oldest].id
store:markOpened(oldest)
server.online = false
sync(client, store)
server.online = true
-- add 20 brand new unread articles on the server so the limit must drop old ones
for i = 131, 150 do
    local id = string.format("%.0f", BASE_ID + i)
    server.items[id] = { id = id, feed_id = 1, title = "New " .. i, html = "<p>n</p>", url = "", is_read = 0, created_on_time = 1700000000 + i }
    server.unread[id] = true
end
-- make the push fail by marking every request offline once pushes start: simulate by wrong key for marking
local real_markRead = client.markRead
client.markRead = function() return false, { kind = "http", detail = "500" } end
ok, summary = sync(client, store)
client.markRead = real_markRead
pass("sync with failed push ok", ok and summary.push_failed == 1)
pass("pending article kept despite limit", store:getItem(oldest) ~= nil)
pass("cache within limit (pending may exceed by its own count)", store:itemCount() <= MAX + 1)
pass("empty url stored as nil", store:getItem(string.format("%.0f", BASE_ID + 150)).url == nil)

-- Failed batch keeps existing items
local before = store:itemCount()
local real_getItems = client.getItems
client.getItems = function() return false, { kind = "json", detail = "bad" } end
for i = 151, 160 do
    local id = string.format("%.0f", BASE_ID + i)
    server.items[id] = { id = id, feed_id = 1, title = "x", html = "", is_read = 0, created_on_time = 1700000000 + i }
    server.unread[id] = true
end
ok, summary = sync(client, store)
client.getItems = real_getItems
pass("failed batch counted, items kept", ok and summary.failed_batches == 1 and store:itemCount() >= before - 1)

-- Keeping read articles
local keep_store = FeverStore:new{ file = "keep_cache", text_dir = textDir("keep_cache") }
local function syncKeep()
    -- A large limit, so the cache limit does not interfere with these checks.
    return FeverSync.run(client, keep_store, { max_items = 1000, keep_read = true, html = FeverHtml })
end
ok = syncKeep()
local unread_total = countUnread()
pass("keep_read sync ok", ok and keep_store:itemCount() == unread_total)
local read_id = keep_store:getSortedItems(false)[1].id
keep_store:markOpened(read_id)
pass("opened article listed when read shown", #keep_store:getSortedItems(true) == unread_total
    and #keep_store:getSortedItems(false) == unread_total - 1)
ok, summary = syncKeep()
pass("read pushed but article kept", ok and summary.pushed == 1 and keep_store:getItem(read_id) ~= nil and keep_store:getItem(read_id).read)
local web_read = keep_store:getSortedItems(false)[1].id
server.unread[web_read] = nil
syncKeep()
pass("web-read article kept and flagged read", keep_store:getItem(web_read) ~= nil and keep_store:getItem(web_read).read == true)
server.unread[web_read] = true
syncKeep()
pass("marked unread on server clears read flag", keep_store:getItem(web_read).read == nil)

-- Cache limit drops read articles before unread ones, even newer read ones
local limit_store = FeverStore:new{ file = "limit_cache", text_dir = textDir("limit_cache") }
for i = 1, 6 do
    limit_store:putItem({ id = tostring(i), title = "t", text = "", created = i, read = (i >= 5) or nil })
end
local dropped = limit_store:applyLimit(4)
pass("limit drops read first", dropped == 2 and limit_store:getItem("5") == nil and limit_store:getItem("6") == nil
    and limit_store:getItem("1") ~= nil)
limit_store:putItem({ id = "7", title = "t", text = "", created = 7, read = true })
limit_store:markOpened("7")
dropped = limit_store:applyLimit(3)
pass("limit then drops oldest unread, keeps pending", dropped == 2 and limit_store:getItem("7") ~= nil
    and limit_store:getItem("1") == nil and limit_store:getItem("2") == nil)

pass("dropped article's text file removed", not fileExists(limit_store:textPath("1")))
pass("kept article's text file present", fileExists(limit_store:textPath("7")))

-- Text files follow the index: pruned articles lose their file, clear removes everything
pass("pruned article's text file removed", not fileExists(store:textPath(opened[1])))

-- Migration from the old single-file format, and cleanup of orphaned text files
disk["old_cache"] = { items = { ["42"] = { id = "42", title = "Old", text = "Old text", created = 1 } },
    feed_titles = {}, pending_reads = {} }
os.execute("mkdir -p '" .. textDir("old_cache") .. "'")
local orphan = io.open(textDir("old_cache") .. "/999.txt", "wb")
orphan:write("orphan")
orphan:close()
local old_store = FeverStore:new{ file = "old_cache", text_dir = textDir("old_cache") }
pass("old cache text migrated to file", old_store:getText("42") == "Old text" and old_store:getItem("42").text == nil
    and disk["old_cache"].items["42"].text == nil)
pass("orphaned text file removed", not fileExists(textDir("old_cache") .. "/999.txt"))
local stray = io.open(textDir("old_cache") .. "/555.txt", "wb")
stray:write("stray")
stray:close()
old_store:clear()
pass("clear removes text files", not fileExists(old_store:textPath("42")) and old_store:itemCount() == 0)
pass("clear removes text files the index does not know", not fileExists(textDir("old_cache") .. "/555.txt"))
pass("clear empties queued reads and categories", #old_store:getPendingReads() == 0
    and next(old_store.feed_groups) == nil and disk["old_cache"].items and next(disk["old_cache"].items) == nil)

-- Categories
pass("group titles stored", store.group_titles["10"] == "Tech" and store.group_titles["20"] == "News")
pass("feed groups stored", #store.feed_groups["2"] == 2 and store.feed_groups["3"] == nil)
local categories = store:getCategories(false)
pass("three category buckets", #categories == 3)
pass("categories sorted by title, uncategorised last", categories[1].title == "News" and categories[2].title == "Tech"
    and categories[3].id == nil)
local by_feed = { 0, 0, 0 }
for _, item in ipairs(store:getSortedItems(false)) do
    local f = tonumber(item.feed_id)
    by_feed[f] = by_feed[f] + 1
end
pass("article in two categories counted in both", #categories[1].items == by_feed[2]
    and #categories[2].items == by_feed[1] + by_feed[2] and #categories[3].items == by_feed[3])
pass("category unread counts", categories[2].unread == #categories[2].items)
local first_tech = categories[2].items[1]
pass("category items newest first", first_tech.created >= categories[2].items[#categories[2].items].created)
store:markOpened(first_tech.id)
pass("opened article leaves category when read hidden", #store:getCategories(false)[2].items == #categories[2].items - 1)
local with_read = store:getCategories(true)
pass("opened article counted as read when shown", #with_read[2].items == #categories[2].items
    and with_read[2].unread == categories[2].unread - 1)
store = newStore()
pass("categories persisted", store.group_titles["10"] == "Tech" and #store.feed_groups["2"] == 2)

-- Google Reader API
local GReaderClient = require("kofever_greader_client")
local Http = require("kofever_http")
pass("hexToDecimal small values", GReaderClient.hexToDecimal("0") == "0" and GReaderClient.hexToDecimal("ff") == "255")
pass("hexToDecimal beyond 2^53 is exact", GReaderClient.hexToDecimal("ffffffffffffffff") == "18446744073709551615"
    and GReaderClient.hexToDecimal("1234567890ABCDEF") == "1311768467294899695")
pass("hexToDecimal keeps FreshRSS-sized IDs", GReaderClient.hexToDecimal("00060a2f3b4c5d6e") == "1700047834865006")
pass("hexToDecimal rejects non-hex", GReaderClient.hexToDecimal("xyz") == nil and GReaderClient.hexToDecimal("") == nil)
pass("long-form item ID converted", GReaderClient.itemIdToDecimal("tag:google.com,2005:reader/item/00060a24181e407b") == "1700000000000123"
    and GReaderClient.itemIdToDecimal("1700000000000123") == "1700000000000123")
pass("form encoding escapes reserved characters", Http.formEncode{ { "p", "a&b=c d+/" } } == "p=a%26b%3Dc%20d%2B%2F")

local ok_login, login_err = GReaderClient.findEndpoint("https://rss.example.com", GREADER_USER, "wrong")
pass("Google Reader wrong password is an auth error", not ok_login and login_err.kind == "auth")
local base_url, auth
ok_login, base_url, auth = GReaderClient.findEndpoint("https://rss.example.com", GREADER_USER, GREADER_PASS)
pass("FreshRSS endpoint found and password with &, =, + and space sent intact",
    ok_login and base_url == "https://rss.example.com/api/greader.php" and auth == GREADER_AUTH)
local mini_ok, mini_base = GReaderClient.findEndpoint("https://mini.example.com", GREADER_USER, GREADER_PASS)
pass("root-URL server endpoint found by falling back", mini_ok and mini_base == "https://mini.example.com")
local direct_ok, direct_base = GReaderClient.findEndpoint("https://rss.example.com/api/greader.php", GREADER_USER, GREADER_PASS)
pass("explicit greader.php URL used as is", direct_ok and direct_base == "https://rss.example.com/api/greader.php")
local nowhere_ok, nowhere_err = GReaderClient.findEndpoint("https://nothing.example.com", GREADER_USER, GREADER_PASS)
pass("no Google Reader endpoint is an http error", not nowhere_ok and nowhere_err.kind == "http")

local bad_client = GReaderClient:new{ base_url = base_url, auth = "alice/wrong" }
local bad_ok, bad_err = bad_client:checkAuth()
pass("bad auth token rejected", not bad_ok and bad_err.kind == "auth")

local greader = GReaderClient:new{ base_url = base_url, auth = auth }
pass("auth token accepted", (greader:checkAuth()))
greader.IDS_PAGE_SIZE = 7
server.greader_calls = {}
local ids_ok, gids = greader:getUnreadIds()
local id_calls = 0
for _, call in ipairs(server.greader_calls) do
    if call.path == "/reader/api/0/stream/items/ids" then id_calls = id_calls + 1 end
end
local expected = sortedUnreadDesc()
pass("unread IDs listed across pages without duplicates", ids_ok and #gids == #expected and gids[1] == expected[1]
    and gids[#gids] == expected[#expected] and id_calls == math.floor(#expected / 7) + 1)

local feeds_ok, gfeeds = greader:getFeeds()
pass("feeds and labels read", feeds_ok and gfeeds.feed_titles["2"] == "Feed Two" and gfeeds.group_titles.Tech == "Tech"
    and #gfeeds.feed_groups["2"] == 2 and gfeeds.feed_groups["3"] == nil)

local items_ok, gitems = greader:getItems({ expected[1], expected[2] })
local gfirst = gitems and gitems[1]
pass("items converted to Fever shape", items_ok and #gitems == 2 and gfirst.id == expected[1]
    and gfirst.feed_id == server.items[expected[1]].feed_id .. "" and gfirst.url == server.items[expected[1]].url
    and gfirst.html == server.items[expected[1]].html and gfirst.is_read == 0
    and gfirst.created_on_time == server.items[expected[1]].created_on_time)

-- Full sync through the Google Reader client
local gstore = FeverStore:new{ file = "greader_cache", text_dir = textDir("greader_cache") }
local function syncGReader()
    return FeverSync.run(greader, gstore, { max_items = 1000, html = FeverHtml })
end
local gsync_ok, gsummary = syncGReader()
pass("Google Reader sync downloads every unread article", gsync_ok and gstore:itemCount() == #expected
    and gsummary.new == #expected)
local gnewest = gstore:getItem(expected[1])
local gsource = server.items[expected[1]]
pass("Google Reader article title and text stored", gnewest ~= nil
    and gnewest.title == FeverHtml.decodeEntities(gsource.title)
    and gstore:getText(expected[1]) == FeverHtml.toPlainText(gsource.html))
pass("Google Reader categories stored", gstore.group_titles.Tech == "Tech" and #gstore:getCategories(false) == 3)
for i = 1, 3 do
    gstore:markOpened(expected[i])
end
server.greader_calls = {}
gsync_ok, gsummary = syncGReader()
local edit_calls = 0
for _, call in ipairs(server.greader_calls) do
    if call.path == "/reader/api/0/edit-tag" then edit_calls = edit_calls + 1 end
end
pass("three reads pushed in one edit-tag request", gsync_ok and gsummary.pushed == 3 and edit_calls == 1
    and not server.unread[expected[1]] and not server.unread[expected[3]] and #gstore:getPendingReads() == 0)
pass("read articles pruned after Google Reader sync", gstore:getItem(expected[1]) == nil and gsummary.removed == 3)

gstore:markOpened(expected[4])
greader.token = "stale"
gsync_ok, gsummary = syncGReader()
pass("rejected batch keeps reads queued", gsync_ok and gsummary.push_failed == 1 and #gstore:getPendingReads() == 1)
pass("article still unread on server after rejected batch", server.unread[expected[4]] == true)

os.execute("rm -rf '" .. TMP .. "'")
print("all tests passed")
