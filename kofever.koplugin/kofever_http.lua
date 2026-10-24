--[[--
Minimal HTTP helper shared by the API clients. No UI.

`Http.request` returns `true, body` or `false, err`, where `err` is
`{ kind = "network"|"http"|"auth", detail = string, code = number|nil }`.

@module koplugin.kofever.http
--]]

local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local Http = {}

--- Percent-encodes a value for a URL query string or a form body.
function Http.urlEncode(value)
    return (tostring(value):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

--- Builds an `application/x-www-form-urlencoded` string.
-- @tparam table fields array of `{ key, value }` pairs; a key may repeat
function Http.formEncode(fields)
    local parts = {}
    for _, field in ipairs(fields) do
        table.insert(parts, Http.urlEncode(field[1]) .. "=" .. Http.urlEncode(field[2]))
    end
    return table.concat(parts, "&")
end

--- Sends one HTTP request.
-- @tparam table opts `{ url, method = "GET"|"POST", headers = table, body = string, timeouts = { block, total } }`
-- @treturn bool success (HTTP 200)
-- @treturn string response body, or an error table
function Http.request(opts)
    local headers = {}
    for key, value in pairs(opts.headers or {}) do
        headers[key] = value
    end
    local source
    if opts.body then
        headers["Content-Type"] = headers["Content-Type"] or "application/x-www-form-urlencoded"
        headers["Content-Length"] = tostring(#opts.body)
        source = ltn12.source.string(opts.body)
    end

    local timeouts = opts.timeouts
    local block_timeout, total_timeout = socketutil:set_timeout(
        timeouts and timeouts[1] or socketutil.LARGE_BLOCK_TIMEOUT,
        timeouts and timeouts[2] or socketutil.LARGE_TOTAL_TIMEOUT)
    local sink = {}
    local request = {
        url = opts.url,
        method = opts.method or "GET",
        headers = headers,
        source = source,
        sink = socketutil.table_sink(sink),
    }

    -- Never log headers or the body: they hold credentials.
    logger.dbg("KOFever:", request.method, opts.url)
    local ok, code, resp_headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        logger.warn("KOFever: request raised an error:", code)
        return false, { kind = "network", detail = tostring(code) }
    end
    if resp_headers == nil then
        local detail = socketutil.describe_error(code, block_timeout, total_timeout) or tostring(status or code)
        logger.warn("KOFever: network error:", detail)
        return false, { kind = "network", detail = detail }
    end
    if code == 401 or code == 403 then
        logger.warn("KOFever: authorisation refused:", code)
        return false, { kind = "auth", detail = tostring(status or code), code = code }
    end
    if code ~= 200 then
        logger.warn("KOFever: HTTP error:", code, status)
        return false, { kind = "http", detail = tostring(status or code), code = code }
    end
    return true, table.concat(sink)
end

return Http
