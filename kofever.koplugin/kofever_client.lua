--[[--
Minimal Fever API client, as implemented by FreshRSS at {server}/api/fever.php.

Every call is a POST to `{server}/api/fever.php?api&<flags>` with `api_key` in the form body.
This module does no UI work: each call returns `true, result` or `false, err`,
where `err` is a table `{ kind = "network"|"http"|"json"|"auth", detail = string }`.

@module koplugin.kofever.client
--]]

local Http = require("kofever_http")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local rapidjson = require("rapidjson")
local socketutil = require("socketutil")

local FeverClient = {
    -- FreshRSS returns at most 50 items per `items` call (LIMIT 50 in its FeverDAO).
    MAX_IDS_PER_REQUEST = 50,
}

function FeverClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--- Computes the Fever API key: lowercase hex MD5 of "username:apipassword".
function FeverClient.makeApiKey(username, api_password)
    return md5(username .. ":" .. api_password):lower()
end

--- Returns an article or feed ID as a string.
-- FreshRSS sends item IDs as strings and feed IDs as numbers. Numbers are formatted
-- without an exponent so that they match the IDs from `unread_item_ids`.
function FeverClient.idToString(id)
    if type(id) == "number" then
        return string.format("%.0f", id)
    elseif type(id) == "string" then
        return id
    end
    return nil
end

--- Sends one Fever request.
-- @string flags query-string flags appended after `?api`, e.g. "feeds" or "items&with_ids=1,2"
-- @tparam[opt] table fields extra form fields for the POST body
-- @tparam[opt] table timeouts `{ block, total }` in seconds
-- @treturn bool success
-- @treturn table decoded JSON response, or an error table
function FeverClient:request(flags, fields, timeouts)
    local url = self.server .. "/api/fever.php?api"
    if flags and flags ~= "" then
        url = url .. "&" .. flags
    end

    local body_fields = { { "api_key", self.api_key } }
    for key, value in pairs(fields or {}) do
        table.insert(body_fields, { key, value })
    end

    local ok, content = Http.request{
        url = url,
        method = "POST",
        headers = { ["Accept"] = "application/json" },
        body = Http.formEncode(body_fields),
        timeouts = timeouts,
    }
    if not ok then
        return false, content
    end

    local decoded_ok, data = pcall(rapidjson.decode, content)
    if not decoded_ok or type(data) ~= "table" then
        logger.warn("KOFever: response is not valid JSON:", content:sub(1, 200))
        return false, { kind = "json", detail = "invalid JSON" }
    end
    if tonumber(data.auth) ~= 1 then
        logger.warn("KOFever: authentication refused by server")
        return false, { kind = "auth", detail = "auth = " .. tostring(data.auth) }
    end
    return true, data
end

--- Checks that the server accepts the API key.
function FeverClient:checkAuth()
    return self:request("")
end

--- Fetches feed titles and the categories (Fever "groups") they belong to, in one request.
-- @treturn bool success
-- @treturn table `{ feed_titles, group_titles, feed_groups }`, or an error table.
-- `feed_titles` maps feed ID to title. `group_titles` maps group ID to title and
-- `feed_groups` maps feed ID to an array of group IDs; both are nil if the server sent no groups.
function FeverClient:getFeeds()
    local ok, data = self:request("groups&feeds")
    if not ok then return false, data end
    if type(data.feeds) ~= "table" then
        logger.warn("KOFever: feeds response has no feeds list")
        return false, { kind = "json", detail = "missing feeds" }
    end
    local result = { feed_titles = {} }
    for _, feed in ipairs(data.feeds) do
        local id = FeverClient.idToString(feed.id)
        if id then
            result.feed_titles[id] = type(feed.title) == "string" and feed.title or ""
        end
    end

    if type(data.groups) == "table" and type(data.feeds_groups) == "table" then
        result.group_titles = {}
        for _, group in ipairs(data.groups) do
            local id = FeverClient.idToString(group.id)
            if id then
                result.group_titles[id] = type(group.title) == "string" and group.title or ""
            end
        end
        result.feed_groups = {}
        for _, link in ipairs(data.feeds_groups) do
            local group_id = FeverClient.idToString(link.group_id)
            if group_id and type(link.feed_ids) == "string" then
                for feed_id in link.feed_ids:gmatch("%d+") do
                    result.feed_groups[feed_id] = result.feed_groups[feed_id] or {}
                    table.insert(result.feed_groups[feed_id], group_id)
                end
            end
        end
    end
    return true, result
end

--- Fetches the IDs of every unread item.
-- @treturn bool success
-- @treturn table array of ID strings, or an error table
function FeverClient:getUnreadIds()
    local ok, data = self:request("unread_item_ids")
    if not ok then return false, data end
    if type(data.unread_item_ids) ~= "string" then
        logger.warn("KOFever: response has no unread_item_ids string")
        return false, { kind = "json", detail = "missing unread_item_ids" }
    end
    local ids = {}
    for id in data.unread_item_ids:gmatch("%d+") do
        table.insert(ids, id)
    end
    return true, ids
end

--- Fetches full items for up to MAX_IDS_PER_REQUEST IDs.
-- @tparam table ids array of ID strings
-- @treturn bool success
-- @treturn table array of raw item tables, or an error table
function FeverClient:getItems(ids)
    local flags = "items&with_ids=" .. table.concat(ids, ",")
    -- Article bodies can be large, so allow the file-download timeouts.
    local ok, data = self:request(flags, nil, { socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT })
    if not ok then return false, data end
    if type(data.items) ~= "table" then
        logger.warn("KOFever: items response has no items list")
        return false, { kind = "json", detail = "missing items" }
    end
    return true, data.items
end

--- Marks one item as read on the server.
-- The mark fields go in the POST body, as the Fever spec describes. FreshRSS reads them from either place.
-- @string id item ID
-- @treturn bool success
function FeverClient:markRead(id)
    local ok, err = self:request("", { mark = "item", as = "read", id = id })
    return ok, not ok and err or nil
end

return FeverClient
