--[[--
Google Reader API client, as implemented by FreshRSS at {server}/api/greader.php
(and by other servers at their own base URL).

It offers the same methods as `kofever_client.lua` (`checkAuth`, `getFeeds`, `getUnreadIds`,
`getItems`, `markRead`, `idToString`, `MAX_IDS_PER_REQUEST`) and returns items in the same
shape as Fever items (`id, feed_id, title, url, html, created_on_time, is_read`), so the sync
and the store work unchanged. It adds `markReadMany` for marking several items in one request.

Every call returns `true, result` or `false, err`, where `err` is
`{ kind = "network"|"http"|"json"|"auth", detail = string }`. No UI.

@module koplugin.kofever.greader_client
--]]

local FeverClient = require("kofever_client")
local Http = require("kofever_http")
local logger = require("logger")
local rapidjson = require("rapidjson")
local socketutil = require("socketutil")

local READING_LIST = "user/-/state/com.google/reading-list"
local STATE_READ = "user/-/state/com.google/read"

local GReaderClient = {
    -- Kept the same as the Fever client to bound memory use per request on the device.
    MAX_IDS_PER_REQUEST = 50,
    -- Unread IDs are listed in pages of this size, up to MAX_ID_PAGES pages.
    IDS_PAGE_SIZE = 1000,
    MAX_ID_PAGES = 100,
    idToString = FeverClient.idToString,
}

function GReaderClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--- Converts a hexadecimal string to decimal exactly, using string arithmetic.
-- Item IDs can exceed 2^53, beyond which Lua numbers lose precision.
-- @treturn string|nil decimal digits, or nil if `hex` is not hexadecimal
function GReaderClient.hexToDecimal(hex)
    if type(hex) ~= "string" or hex == "" or hex:find("%X") then
        return nil
    end
    local digits = { 0 } -- base 10, least significant first
    for i = 1, #hex do
        local carry = tonumber(hex:sub(i, i), 16)
        for j = 1, #digits do
            local value = digits[j] * 16 + carry
            digits[j] = value % 10
            carry = math.floor(value / 10)
        end
        while carry > 0 do
            table.insert(digits, carry % 10)
            carry = math.floor(carry / 10)
        end
    end
    local out = {}
    for j = #digits, 1, -1 do
        table.insert(out, digits[j])
    end
    local decimal = table.concat(out):gsub("^0+", "")
    return decimal ~= "" and decimal or "0"
end

--- Normalises an item ID to decimal digits. Accepts decimal IDs and the long form
-- `tag:google.com,2005:reader/item/<16 hex digits>`.
function GReaderClient.itemIdToDecimal(id)
    id = FeverClient.idToString(id)
    if not id then
        return nil
    end
    if id:match("^%d+$") then
        return id
    end
    return GReaderClient.hexToDecimal(id:match("item/(%x+)$"))
end

local function decodeJson(content)
    local ok, data = pcall(rapidjson.decode, content)
    if not ok or type(data) ~= "table" then
        logger.warn("KOFever: response is not valid JSON:", content:sub(1, 200))
        return false, { kind = "json", detail = "invalid JSON" }
    end
    return true, data
end

--- Logs in at one base URL with `accounts/ClientLogin`.
-- @treturn bool success
-- @treturn string auth token, or an error table
function GReaderClient.login(base_url, username, password)
    local ok, content = Http.request{
        url = base_url .. "/accounts/ClientLogin",
        method = "POST",
        body = Http.formEncode{ { "Email", username }, { "Passwd", password } },
    }
    if not ok then
        return false, content
    end
    local auth = content:match("Auth=([^\r\n]+)")
    if not auth or auth == "" then
        logger.warn("KOFever: ClientLogin response has no Auth line")
        return false, { kind = "json", detail = "missing Auth" }
    end
    return true, auth
end

--- Finds the Google Reader endpoint for a server and logs in.
-- Tries `<server>/api/greader.php` (FreshRSS) first, then `<server>` itself (other servers).
-- Every candidate is tried, because a server may answer an unknown path with 401 as well as
-- with 404. If none works, an authorisation failure is reported in preference to other errors,
-- since it means an endpoint exists but the login is wrong. A network error stops the search.
-- @treturn bool success
-- @treturn string base URL to use for API calls, or an error table
-- @treturn string auth token
function GReaderClient.findEndpoint(server, username, password)
    local candidates = { server .. "/api/greader.php", server }
    if server:match("/api/greader%.php$") then
        candidates = { server }
    end
    local first_err, auth_err
    for _, base_url in ipairs(candidates) do
        local ok, result = GReaderClient.login(base_url, username, password)
        if ok then
            return true, base_url, result
        end
        if result.kind == "network" then
            return false, result
        end
        first_err = first_err or result
        if result.kind == "auth" then
            auth_err = auth_err or result
        end
    end
    return false, auth_err or first_err
end

--- Sends one authorised API call to `<base_url>/reader/api/0/<path>`.
-- @tparam table query array of `{ key, value }` pairs for the URL
-- @tparam[opt] table form array of `{ key, value }` pairs; makes the call a POST
-- @treturn bool success
-- @treturn string response body, or an error table
function GReaderClient:call(path, query, form, timeouts)
    local url = self.base_url .. "/reader/api/0/" .. path
    if query and #query > 0 then
        url = url .. "?" .. Http.formEncode(query)
    end
    return Http.request{
        url = url,
        method = form and "POST" or "GET",
        headers = { ["Authorization"] = "GoogleLogin auth=" .. self.auth },
        body = form and Http.formEncode(form) or nil,
        timeouts = timeouts,
    }
end

function GReaderClient:callJson(path, query, form, timeouts)
    local ok, content = self:call(path, query, form, timeouts)
    if not ok then
        return false, content
    end
    return decodeJson(content)
end

--- Returns the action token needed for write calls, fetching it once per client.
function GReaderClient:getToken()
    if self.token then
        return true, self.token
    end
    local ok, content = self:call("token")
    if not ok then
        return false, content
    end
    local token = content:match("^%s*(%S+)")
    if not token then
        return false, { kind = "json", detail = "empty token" }
    end
    self.token = token
    return true, token
end

--- Checks that the server accepts the stored auth token.
function GReaderClient:checkAuth()
    return self:getToken()
end

--- Fetches feed titles and categories (labels).
-- @treturn bool success
-- @treturn table `{ feed_titles, group_titles, feed_groups }` like `FeverClient:getFeeds`, or an error table
function GReaderClient:getFeeds()
    local ok, data = self:callJson("subscription/list", { { "output", "json" } })
    if not ok then return false, data end
    if type(data.subscriptions) ~= "table" then
        logger.warn("KOFever: subscription list has no subscriptions")
        return false, { kind = "json", detail = "missing subscriptions" }
    end
    local result = { feed_titles = {}, group_titles = {}, feed_groups = {} }
    for _, sub in ipairs(data.subscriptions) do
        local feed_id = type(sub.id) == "string" and sub.id:match("^feed/(.+)$")
        if feed_id then
            result.feed_titles[feed_id] = type(sub.title) == "string" and sub.title or ""
            if type(sub.categories) == "table" then
                for _, category in ipairs(sub.categories) do
                    local label = type(category) == "table" and category.label
                    if type(label) ~= "string" or label == "" then
                        label = type(category) == "table" and type(category.id) == "string"
                            and category.id:match("/label/(.+)$")
                    end
                    if label then
                        -- The label name doubles as the group ID.
                        result.group_titles[label] = label
                        result.feed_groups[feed_id] = result.feed_groups[feed_id] or {}
                        table.insert(result.feed_groups[feed_id], label)
                    end
                end
            end
        end
    end
    return true, result
end

--- Fetches the IDs of every unread item, page by page.
-- The sync treats this list as complete and prunes cached articles that are missing from it,
-- so anything short of a complete list (a reply without `itemRefs`, a repeated continuation
-- token, or more pages than MAX_ID_PAGES) is returned as an error rather than a partial list.
-- @treturn bool success
-- @treturn table array of decimal ID strings, or an error table
function GReaderClient:getUnreadIds()
    local ids, seen = {}, {}
    local continuation
    local used_continuations = {}
    for _ = 1, self.MAX_ID_PAGES do
        local query = {
            { "s", READING_LIST },
            { "xt", STATE_READ },
            { "n", self.IDS_PAGE_SIZE },
            { "output", "json" },
        }
        if continuation then
            table.insert(query, { "c", continuation })
        end
        local ok, data = self:callJson("stream/items/ids", query)
        if not ok then return false, data end
        local refs = data.itemRefs
        if refs == nil then
            logger.warn("KOFever: unread ID response has no itemRefs")
            return false, { kind = "json", detail = "missing itemRefs" }
        elseif rapidjson.null ~= nil and refs == rapidjson.null then
            refs = {} -- an explicit null is an empty list
        elseif type(refs) ~= "table" then
            return false, { kind = "json", detail = "bad itemRefs" }
        end
        for _, ref in ipairs(refs) do
            local id = type(ref) == "table" and GReaderClient.itemIdToDecimal(ref.id)
            if id and not seen[id] then
                seen[id] = true
                table.insert(ids, id)
            end
        end
        local next_continuation = FeverClient.idToString(data.continuation)
        if not next_continuation or next_continuation == "" then
            return true, ids
        end
        if used_continuations[next_continuation] then
            logger.warn("KOFever: unread ID paging repeated a continuation token")
            return false, { kind = "json", detail = "repeated continuation" }
        end
        used_continuations[next_continuation] = true
        continuation = next_continuation
    end
    logger.warn("KOFever: unread ID list longer than", self.MAX_ID_PAGES, "pages")
    return false, { kind = "json", detail = "too many unread pages" }
end

-- Converts a Google Reader item into the Fever item shape the sync expects.
local function toFeverItem(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local id = GReaderClient.itemIdToDecimal(raw.id)
    if not id then
        return nil
    end
    local feed_id = type(raw.origin) == "table" and type(raw.origin.streamId) == "string"
        and raw.origin.streamId:match("^feed/(.+)$") or nil
    local url
    for _, key in ipairs{ "canonical", "alternate" } do
        local links = raw[key]
        if not url and type(links) == "table" and type(links[1]) == "table" and type(links[1].href) == "string" then
            url = links[1].href
        end
    end
    local html
    for _, key in ipairs{ "summary", "content" } do
        local part = raw[key]
        if not html and type(part) == "table" and type(part.content) == "string" then
            html = part.content
        end
    end
    local is_read = 0
    if type(raw.categories) == "table" then
        for _, category in ipairs(raw.categories) do
            if type(category) == "string" and category:match("/state/com%.google/read$") then
                is_read = 1
            end
        end
    end
    return {
        id = id,
        feed_id = feed_id,
        title = raw.title,
        url = url,
        html = html,
        created_on_time = raw.published,
        is_read = is_read,
    }
end

--- Fetches full items for up to MAX_IDS_PER_REQUEST IDs.
-- @tparam table ids array of decimal ID strings
-- @treturn bool success
-- @treturn table array of items in Fever shape, or an error table
function GReaderClient:getItems(ids)
    local form = {}
    for _, id in ipairs(ids) do
        table.insert(form, { "i", id })
    end
    -- Article bodies can be large, so allow the file-download timeouts.
    local ok, data = self:callJson("stream/items/contents", { { "output", "json" } }, form,
        { socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT })
    if not ok then return false, data end
    if type(data.items) ~= "table" then
        logger.warn("KOFever: items response has no items list")
        return false, { kind = "json", detail = "missing items" }
    end
    local items = {}
    for _, raw in ipairs(data.items) do
        local item = toFeverItem(raw)
        if item then
            table.insert(items, item)
        end
    end
    return true, items
end

--- Marks several items as read in one request.
-- @tparam table ids array of decimal ID strings
-- @treturn bool success
function GReaderClient:markReadMany(ids)
    local token_ok, token = self:getToken()
    if not token_ok then
        return false, token
    end
    local form = { { "T", token }, { "a", STATE_READ } }
    for _, id in ipairs(ids) do
        table.insert(form, { "i", id })
    end
    local ok, err = self:call("edit-tag", nil, form)
    return ok, not ok and err or nil
end

--- Marks one item as read.
function GReaderClient:markRead(id)
    return self:markReadMany{ id }
end

return GReaderClient
