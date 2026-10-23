--[[--
Local article cache for offline reading.

The index is a LuaSettings file (`file`) holding:

- `items`: table keyed by article ID string. Each value is
  `{ id, title, url, feed_id, created, read }`. `read` is set locally when
  the article is opened, so it can be hidden from the list but still reopened offline.
- `feed_titles`: table keyed by feed ID string.
- `group_titles`: category (Fever group) titles keyed by group ID string.
- `feed_groups`: arrays of group ID strings keyed by feed ID string.
- `pending_reads`: array of article ID strings opened locally but not yet marked read on the server.

Article text is kept out of the index, one file per article in `text_dir`, so the index
stays small and quick to rewrite even with a large cache.

@module koplugin.kofever.store
--]]

local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Store = {}

local TEXT_SUFFIX = ".txt"

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
    self.group_titles = self.settings:readSetting("group_titles", {})
    self.feed_groups = self.settings:readSetting("feed_groups", {})
    self.pending_reads = self.settings:readSetting("pending_reads", {})
    if lfs.attributes(self.text_dir, "mode") ~= "directory" then
        lfs.mkdir(self.text_dir)
    end

    -- Earlier versions kept the text in the index: move it out to text files.
    local migrated = false
    for id, item in pairs(self.items) do
        if item.text then
            self:writeText(id, item.text)
            item.text = nil
            migrated = true
        end
    end
    if migrated then
        self:save()
    end

    -- Remove text files the index does not know about (left by an interrupted sync).
    local known = {}
    for id in pairs(self.items) do
        known[self:textName(id)] = true
    end
    for name in lfs.dir(self.text_dir) do
        if name:sub(-#TEXT_SUFFIX) == TEXT_SUFFIX and not known[name] then
            os.remove(self.text_dir .. "/" .. name)
        end
    end
end

function Store:textName(id)
    -- FreshRSS IDs are digits; anything else is made safe for a file name.
    return (id:gsub("[^%w_-]", "_")) .. TEXT_SUFFIX
end

function Store:textPath(id)
    return self.text_dir .. "/" .. self:textName(id)
end

function Store:writeText(id, text)
    local file = io.open(self:textPath(id), "wb")
    if not file then
        return false
    end
    file:write(text or "")
    file:close()
    return true
end

--- Returns the article text, or nil if its file is missing.
function Store:getText(id)
    local file = io.open(self:textPath(id), "rb")
    if not file then
        return nil
    end
    local text = file:read("*a")
    file:close()
    return text
end

--- Writes the cache to disk.
function Store:save()
    self.settings:saveSetting("items", self.items)
    self.settings:saveSetting("feed_titles", self.feed_titles)
    self.settings:saveSetting("group_titles", self.group_titles)
    self.settings:saveSetting("feed_groups", self.feed_groups)
    self.settings:saveSetting("pending_reads", self.pending_reads)
    self.settings:flush()
end

--- Empties the cache, including queued reads, and writes it to disk.
-- Every text file in `text_dir` is removed, not only those the index knows about.
function Store:clear()
    for name in lfs.dir(self.text_dir) do
        if name:sub(-#TEXT_SUFFIX) == TEXT_SUFFIX then
            os.remove(self.text_dir .. "/" .. name)
        end
    end
    self.items = {}
    self.feed_titles = {}
    self.group_titles = {}
    self.feed_groups = {}
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

function Store:setGroups(group_titles, feed_groups)
    self.group_titles = group_titles
    self.feed_groups = feed_groups
end

--- Groups cached articles by category for browsing.
-- An article is listed under every category its feed belongs to. Articles whose feed has
-- no known category are collected in one bucket with `id = nil`, sorted last.
-- @bool include_read also include articles opened locally
-- @treturn table array of `{ id, title, items, unread }`; `items` are sorted newest first
function Store:getCategories(include_read)
    local buckets, list = {}, {}
    for _, item in ipairs(self:getSortedItems(include_read)) do
        local group_ids = item.feed_id and self.feed_groups[item.feed_id]
        if not group_ids or #group_ids == 0 then
            group_ids = { false }
        end
        for _, group_id in ipairs(group_ids) do
            local bucket = buckets[group_id]
            if not bucket then
                bucket = {
                    id = group_id or nil,
                    title = group_id and self.group_titles[group_id] or nil,
                    items = {},
                    unread = 0,
                }
                buckets[group_id] = bucket
                table.insert(list, bucket)
            end
            table.insert(bucket.items, item)
            if not item.read then
                bucket.unread = bucket.unread + 1
            end
        end
    end
    table.sort(list, function(a, b)
        if (a.id == nil) ~= (b.id == nil) then
            return b.id == nil
        end
        local a_title, b_title = (a.title or ""):lower(), (b.title or ""):lower()
        if a_title ~= b_title then
            return a_title < b_title
        end
        return (a.id or "") < (b.id or "")
    end)
    return list
end

function Store:itemCount()
    local count = 0
    for _ in pairs(self.items) do
        count = count + 1
    end
    return count
end

--- Adds an article. Its `text` field is written to its own file and not kept in the index.
function Store:putItem(item)
    self:writeText(item.id, item.text)
    item.text = nil
    self.items[item.id] = item
end

function Store:removeItem(id)
    self.items[id] = nil
    os.remove(self:textPath(id))
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

--- Drops articles until at most `max_items` remain: read articles first, then unread,
-- oldest first within each group. Articles waiting in `pending_reads` are never dropped.
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
        if (a.read or false) ~= (b.read or false) then
            return a.read == true
        end
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
        self:removeItem(item.id)
        count = count - 1
        dropped = dropped + 1
    end
    return dropped
end

return Store
