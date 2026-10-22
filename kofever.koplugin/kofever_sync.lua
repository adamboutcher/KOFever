--[[--
Sync algorithm between a FeverClient and a Store.

This module has no UI code. Progress is reported through an optional callback,
and the outcome is returned as a summary table.

@module koplugin.kofever.sync
--]]

local Sync = {}

-- Compares two numeric ID strings without converting them to numbers.
-- FreshRSS IDs grow over time, so a larger ID is a newer article.
local function idIsNewer(a, b)
    if #a ~= #b then
        return #a > #b
    end
    return a > b
end

local function toRecord(raw, client, html)
    local id = client.idToString(raw.id)
    if not id then
        return nil
    end
    local title = type(raw.title) == "string" and html.decodeEntities(raw.title) or ""
    if not title:match("%S") then
        title = "(untitled)"
    end
    return {
        id = id,
        title = title,
        url = type(raw.url) == "string" and raw.url ~= "" and raw.url or nil,
        feed_id = client.idToString(raw.feed_id),
        created = tonumber(raw.created_on_time) or 0,
        text = html.toPlainText(type(raw.html) == "string" and raw.html or ""),
    }
end

--- Runs a full sync.
-- @tparam FeverClient client
-- @tparam Store store
-- @tparam table opts `{ max_items = int, keep_read = bool, html = kofever_html, progress = function(stage, current, total) }`
-- With `keep_read`, articles that are read on the server stay cached (flagged read) until the cache limit drops them.
-- @treturn bool true if the sync reached the end, false if it was aborted
-- @treturn table summary `{ pushed, push_failed, new, failed_batches, removed, dropped, not_downloaded, feeds_failed }`
-- @treturn table|nil error table from the client when aborted
function Sync.run(client, store, opts)
    local progress = opts.progress or function() end
    local summary = {
        pushed = 0,
        push_failed = 0,
        new = 0,
        failed_batches = 0,
        removed = 0,
        dropped = 0,
        not_downloaded = 0,
        feeds_failed = false,
    }

    -- 1. Push reads made since the last sync. Failed IDs stay queued.
    local pending = store:getPendingReads()
    local remaining = {}
    local stop_pushing = false
    for i, id in ipairs(pending) do
        if stop_pushing then
            table.insert(remaining, id)
        else
            progress("push", i, #pending)
            local ok, err = client:markRead(id)
            if ok then
                summary.pushed = summary.pushed + 1
            else
                table.insert(remaining, id)
                -- No point waiting on a timeout for every remaining ID.
                if err and (err.kind == "network" or err.kind == "auth") then
                    stop_pushing = true
                end
            end
        end
    end
    summary.push_failed = #remaining
    store:setPendingReads(remaining)
    if summary.pushed > 0 then
        store:save()
    end

    -- 2. Refresh feed names and categories. Keep the old ones on failure.
    progress("feeds")
    local feeds_ok, feeds = client:getFeeds()
    if feeds_ok then
        store:setFeedTitles(feeds.feed_titles)
        if feeds.feed_groups then
            store:setGroups(feeds.group_titles, feeds.feed_groups)
        end
    else
        summary.feeds_failed = true
    end

    -- 3. Get unread IDs. Nothing has been removed yet, so aborting here is safe.
    progress("unread")
    local unread_ok, unread_ids = client:getUnreadIds()
    if not unread_ok then
        store:save()
        return false, summary, unread_ids
    end
    local unread_set = {}
    for _, id in ipairs(unread_ids) do
        unread_set[id] = true
    end

    -- 4. Prune articles that are no longer unread on the server, unless their read is still queued.
    -- When read articles are kept, they are only flagged read and the cache limit removes them later.
    local pending_set = store:pendingSet()
    for id, item in pairs(store.items) do
        if not unread_set[id] and not pending_set[id] then
            if opts.keep_read then
                item.read = true
            else
                store:removeItem(id)
                summary.removed = summary.removed + 1
            end
        elseif unread_set[id] and item.read and not pending_set[id] then
            -- Our read was sent but the server lists it as unread again (for example it was
            -- marked unread in the web interface). The server wins.
            item.read = nil
        end
    end

    -- 5. Fetch missing articles. Only the newest `max_items` unread articles are wanted,
    -- so older ones that the cache limit would drop straight away are not downloaded.
    local newest_first = {}
    for i, id in ipairs(unread_ids) do
        newest_first[i] = id
    end
    table.sort(newest_first, idIsNewer)
    local missing = {}
    for i, id in ipairs(newest_first) do
        if not store:getItem(id) then
            if i <= opts.max_items then
                table.insert(missing, id)
            else
                summary.not_downloaded = summary.not_downloaded + 1
            end
        end
    end

    local batch_size = client.MAX_IDS_PER_REQUEST
    local batch_count = math.ceil(#missing / batch_size)
    for batch = 1, batch_count do
        progress("items", batch, batch_count)
        local ids = {}
        for i = (batch - 1) * batch_size + 1, math.min(batch * batch_size, #missing) do
            table.insert(ids, missing[i])
        end
        local ok, items = client:getItems(ids)
        if ok then
            for _, raw in ipairs(items) do
                if tonumber(raw.is_read) ~= 1 then
                    local record = toRecord(raw, client, opts.html)
                    if record and not store:getItem(record.id) then
                        store:putItem(record)
                        summary.new = summary.new + 1
                    end
                end
            end
            store:save()
        else
            summary.failed_batches = summary.failed_batches + 1
            if items and (items.kind == "network" or items.kind == "auth") then
                -- The connection is gone: the remaining batches would fail the same way.
                summary.failed_batches = summary.failed_batches + (batch_count - batch)
                break
            end
        end
    end

    -- 6. Enforce the cache limit.
    summary.dropped = store:applyLimit(opts.max_items)

    -- 7. Save.
    store:save()
    return true, summary
end

return Sync
