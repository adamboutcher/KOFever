--[[--
Local article cache for offline reading, backed by a LuaSettings file.

The file holds:

- `items`: table keyed by article ID string. Each value is
  `{ id, title, url, feed_id, created, text, read }`. `read` is set locally when
  the article is opened, so it can be hidden from the list but still reopened offline.
- `feed_titles`: table keyed by feed ID string.
- `pending_reads`: array of article ID strings opened locally but not yet marked read on the server.

@module koplugin.kofever.store
--]]

local LuaSettings = require("luasettings")

local Store = {}

function Store:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:load()
    return o
end

function Store:load()
    self.settings = LuaSettings:open(self.file)
    self.items = self.settings:readSetting("items", {})
    self.feed_titles = self.settings:readSetting("feed_titles", {})
    self.pending_reads = self.settings:readSetting("pending_reads", {})
end

--- Writes the cache to disk.
function Store:save()
    self.settings:saveSetting("items", self.items)
    self.settings:saveSetting("feed_titles", self.feed_titles)
    self.settings:saveSetting("pending_reads", self.pending_reads)
    self.settings:flush()
end

--- Empties the cache, including queued reads, and writes it to disk.
function Store:clear()
    self.items = {}
    self.feed_titles = {}
    self.pending_reads = {}
    self:save()
end

function Store:getItem(id)
    return self.items[id]
end

function Store:getFeedTitle(feed_id)
    return feed_id and self.feed_titles[feed_id] or nil
end

function Store:setFeedTitles(titles)
    self.feed_titles = titles
end

function Store:itemCount()
    local count = 0
    for _ in pairs(self.items) do
        count = count + 1
    end
    return count
end

function Store:putItem(item)
    self.items[item.id] = item
end

function Store:removeItem(id)
    self.items[id] = nil
end

--- Returns a set (ID -> true) of IDs waiting to be marked read on the server.
function Store:pendingSet()
    local set = {}
    for _, id in ipairs(self.pending_reads) do
        set[id] = true
    end
    return set
end

function Store:isPending(id)
    for _, pending_id in ipairs(self.pending_reads) do
        if pending_id == id then
            return true
        end
    end
    return false
end

function Store:getPendingReads()
    return self.pending_reads
end

function Store:setPendingReads(ids)
    self.pending_reads = ids
end

--- Records that an article was opened: hides it from the unread list and queues the read for the server.
function Store:markOpened(id)
    local item = self.items[id]
    if item then
        item.read = true
    end
    if not self:isPending(id) then
        table.insert(self.pending_reads, id)
    end
    self:save()
end

--- Returns cached articles sorted newest first.
-- @bool include_read also return articles opened locally
function Store:getSortedItems(include_read)
    local list = {}
    for _, item in pairs(self.items) do
        if include_read or not item.read then
            table.insert(list, item)
        end
    end
    table.sort(list, function(a, b)
        if a.created ~= b.created then
            return (a.created or 0) > (b.created or 0)
        end
        return a.id > b.id
    end)
    return list
end

--- Drops the oldest articles until at most `max_items` remain.
-- Articles waiting in `pending_reads` are never dropped.
-- @treturn int number of articles dropped
function Store:applyLimit(max_items)
    local count = self:itemCount()
    if count <= max_items then
        return 0
    end
    local pending = self:pendingSet()
    local candidates = {}
    for id, item in pairs(self.items) do
        if not pending[id] then
            table.insert(candidates, item)
        end
    end
    table.sort(candidates, function(a, b)
        if a.created ~= b.created then
            return (a.created or 0) < (b.created or 0)
        end
        return a.id < b.id
    end)
    local dropped = 0
    for _, item in ipairs(candidates) do
        if count <= max_items then
            break
        end
        self.items[item.id] = nil
        count = count - 1
        dropped = dropped + 1
    end
    return dropped
end

return Store
