# AGENTS.md

> **Agents: read `README.md` in full as well as this file before making any change.** The two are written to be used together and neither repeats the other: `README.md` describes the plugin's user-facing behaviour (menu items, settings, sync and cache behaviour, installation and releases), which changes must preserve and keep documented; this file covers how the code is put together and what to watch out for when changing it.

Guidance for AI coding agents and new contributors working on KOFever.

## What this is

A KOReader plugin (Lua, running on LuaJIT) that syncs unread articles from a FreshRSS server through the Fever or Google Reader API, stores them on the device for offline reading, and queues reads made offline so they are marked read on the server at the next sync. The main target is a Kindle, so assume a slow CPU, little RAM, slow flash storage and an e-ink screen.

There is no build step. The `kofever.koplugin` folder is copied as-is into `koreader/plugins/` on the device.

## Repository layout

| Path | Purpose |
|---|---|
| `kofever.koplugin/_meta.lua` | Name and description shown in KOReader's plugin manager. Holds the `local version = "dev"` line the release workflow rewrites. |
| `kofever.koplugin/main.lua` | The only UI module: menu entries, login dialog, cache size picker, clear-cache confirmation, category and article lists, article viewer. |
| `kofever.koplugin/kofever_client.lua` | Fever API client. HTTP and JSON only, no UI. |
| `kofever.koplugin/kofever_greader_client.lua` | Google Reader API client with the same interface, returning items in Fever shape. No UI. |
| `kofever.koplugin/kofever_http.lua` | HTTP helper used by both clients: timeouts, sinks, error kinds, form encoding. |
| `kofever.koplugin/kofever_sync.lua` | Sync algorithm. Works on a client and a store passed in; no UI and no HTTP. |
| `kofever.koplugin/kofever_store.lua` | Local cache: a `LuaSettings` index plus one text file per article. |
| `kofever.koplugin/kofever_html.lua` | HTML to plain text. No KOReader dependencies. |
| `tests/run_tests.lua` | Offline test harness: stubs KOReader modules and simulates a FreshRSS server. |
| `.github/workflows/ci.yml` | Lint, version placeholder check and tests on every PR and push to `main`. On PRs, a `package` job then builds a test package (version `pr<number>-<commit>`), uploads it as an artifact and links it from a PR comment it keeps updated. |
| `.github/workflows/release.yml` | On a published release: stamps the tag into `_meta.lua`, zips the plugin folder and attaches it. |
| `.luacheckrc` | Lint settings, based on KOReader's own. |
| `LICENSE` | AGPL-3.0, matching KOReader. Copied into the plugin folder in release zips. |
| `plan.md` | Researched but unbuilt features (currently: fetching the full article). Read the relevant entry before implementing one. |

## Architecture rules

Keep these boundaries; they are what make the sync logic testable without a device.

- `kofever_client.lua` and `kofever_greader_client.lua` must not touch the UI. Every call returns `true, result` or `false, err` where `err` is `{ kind = "network"|"http"|"json"|"auth", detail = string }`. HTTP 401/403 map to `auth`.
- Both clients implement one interface, which is all the sync and `main.lua` use: `checkAuth`, `getFeeds` (`{ feed_titles, group_titles, feed_groups }`), `getUnreadIds` (decimal ID strings), `getItems(ids)` (items in Fever shape: `id, feed_id, title, url, html, created_on_time, is_read`), `markRead(id)`, `idToString`, `MAX_IDS_PER_REQUEST`, and optionally `markReadMany(ids)`, which the sync uses to push reads in batches. Add a new server API as another client with this interface rather than branching in the sync.
- `kofever_sync.lua` must not do HTTP or UI. It reports progress through the `opts.progress(stage, current, total)` callback and returns a summary table.
- `kofever_store.lua` owns all cache file I/O. Other modules go through its methods rather than touching `store.items` or the text files directly (sync reads `store.items` in one loop; keep that read-only apart from the `read` flag).
- `kofever_html.lua` stays free of KOReader requires so it can be tested with plain LuaJIT.
- User-visible text lives in `main.lua`, wrapped in `_()` from `gettext`.

## Data model and invariants

Stored in KOReader's settings directory (`DataStorage:getSettingsDir()`):

- `kofever_settings.lua`: `api_type` (`"fever"`, the default when missing, or `"greader"`), `server`, `api_key` (Fever: lowercase MD5 hex of `username:apipassword`), `greader_url` and `greader_auth` (Google Reader: the endpoint that answered and the token from `ClientLogin`), `account` (MD5 of the lowercased username, only used to notice a change of user), `cache_size`, `show_read_articles`. The plain API password and the username itself are never stored. Saving a login for one API deletes the other API's credentials.
- `kofever_cache.lua` (the index): `items` (by article ID string: `id, title, url, feed_id, created, read`), `feed_titles`, `group_titles`, `feed_groups` (feed ID to an array of group IDs), `pending_reads` (array of article IDs).
- `kofever_articles/<id>.txt`: the plain-text body of each article. Text is kept out of the index on purpose: the index is rewritten on every article open and every sync batch, and with up to 3000 articles it must stay small. `Store:putItem` writes the text file and strips `text` from the record.

Invariants that changes must keep:

1. A read queued in `pending_reads` is never dropped by pruning or the cache limit until the server has accepted it. Only `Store:clear()` (user action or server change) discards it.
2. A failed or interrupted sync never deletes cached articles or queued reads. Sync aborts before pruning if the unread ID list cannot be fetched, and a failed item batch only means those articles are fetched next time.
3. Nothing is marked read on the server except through the client's `markRead` / `markReadMany` for IDs in `pending_reads`.
4. The cache limit drops read articles before unread ones, oldest first within each group, and only downloads the newest unread articles that fit.
5. The index and the text files stay in step: removing an item removes its file, `Store:load` deletes text files the index does not reference, and a missing text file causes the entry to be dropped when opened.
6. Changing the server URL, the API type or the user clears the cache, because article IDs and queued reads belong to the old account. Settings saved before `account` existed have none, so for them only the server and API are compared.

## Sync order (`kofever_sync.lua`)

1. Push `pending_reads`, in batches of `MAX_IDS_PER_REQUEST` when the client has `markReadMany`, otherwise one at a time (stop early on a network or auth error; keep failures queued).
2. Fetch feeds and categories in one request (`?api&groups&feeds`). Keep the old data on failure.
3. Fetch the unread IDs. Abort here on failure; nothing has been removed yet. Clients must return an error rather than a partial list, because the next step treats the list as complete (the Google Reader client fails on a missing `itemRefs`, a repeated continuation token or too many pages).
4. Prune articles no longer unread on the server (or flag them read when `keep_read` is set). If the server lists a locally read, already-pushed article as unread again, the server wins.
5. Download missing articles, newest first by ID, in batches of 50, capped at the cache size.
6. Apply the cache limit, then save.

## KOReader specifics learned the hard way

Check anything not listed here against the KOReader source (`koreader/koreader`, under `frontend/` and `plugins/`) rather than relying on memory. The `wallabag`, `kosync`, `opds` and `calibre` plugins are good references.

- The plugin name comes from the folder name (`kofever.koplugin` gives `kofever`). A `name` field in `_meta.lua` is ignored with a deprecation warning, and KOReader has no version field, which is why the version goes into the description.
- The plugin folder is only on `package.path` while `main.lua` is loading, so require the plugin's own modules at the top of `main.lua`, never lazily.
- `package.loaded` is shared by all plugins, so module file names are prefixed `kofever_` to avoid collisions.
- `main.lua` is loaded once but the plugin is instantiated separately for the file manager and for the reader. The store is a module-level singleton (`getStore()`) so both instances share one cache.
- HTTP: `socket.http` handles `https://` URLs (KOReader's Wikipedia lookup relies on this). Wrap requests with `socketutil:set_timeout(...)` / `socketutil:reset_timeout()` and use `socketutil.table_sink` so the total timeout is enforced.
- JSON: `rapidjson` is available on all builds. Treat any non-table result as an error; nulls are not Lua `nil`.
- MD5: `require("ffi/sha2").md5` returns lowercase hex.
- Run network work through `NetworkMgr:runWhenOnline(callback)`.
- `LuaSettings:readSetting(key, default)` stores the default in the data; call `flush()` to write to disk.
- `MultiInputDialog` fields accept `text_type = "password"`; call `dialog:onShowKeyboard()` after showing it.
- `Menu` rows support `text`, `mandatory` (right-hand text), `bold` and `dim`, but not italic. The right-hand text is never truncated; the title gets whatever width is left.
- `Menu` only shows its back arrow when `onReturn` is set, and enables it when `menu.paths` is non-empty. The category browser manages `paths` itself (the same pattern as the Calibre plugin's search) and overrides `onClose` so the close button and Back key go up a level first.
- `TextViewer` accepts `close_callback`, and every way of closing it goes through `onClose`. The article list stays open under the viewer and is rebuilt in that callback. Extra buttons go in `buttons_table`; set `add_default_buttons = true` to keep its own Find/top/bottom/Close row. The Previous/Next buttons close the viewer with `UIManager:close` (skipping `onClose`) and open the next article, so the list is rebuilt only once reading stops, positioned on the last article viewed.
- The sync blocks the UI loop, so progress messages are shown with `UIManager:show` followed by `UIManager:forceRePaint()`.

## FreshRSS Fever specifics

Verified against FreshRSS's `p/api/fever.php`:

- `api_key` is read from the POST body only. Query flags (`feeds`, `groups`, `items`, `unread_item_ids`) and `mark`/`as`/`id` are read from `$_REQUEST`, so either the URL or the body works. The client puts flags in the URL and mark fields in the body, as the Fever spec describes.
- `items&with_ids=` returns at most 50 items per request (`LIMIT 50`), hence `MAX_IDS_PER_REQUEST = 50`.
- Item IDs are sent as strings, feed and group IDs as numbers. Always normalise with `FeverClient.idToString`, which formats numbers without an exponent so they match the IDs from `unread_item_ids`.
- Item IDs grow over time, so a larger ID is a newer article. `idIsNewer` compares them as strings by length, then lexically, to avoid precision loss.
- `feeds_groups` is returned with both the `feeds` and the `groups` flags.
- Titles go through `escapeToUnicodeAlternative`, which swaps `&`, `<` and `>` for full-width look-alikes. `displayTitle` in `main.lua` maps them back for display only.

## FreshRSS Google Reader specifics

Verified against FreshRSS's `p/api/greader.php` and `app/Models/Entry.php` (`toGReader`):

- Login is `POST accounts/ClientLogin` with `Email` and `Passwd` form fields (GET is deprecated because the password can end up in logs). The response is plain text with an `Auth=` line. FreshRSS's token is derived from the API password hash and does not expire, so it is stored like the Fever key.
- API calls are `<base>/reader/api/0/<path>` with the header `Authorization: GoogleLogin auth=<token>`. Write calls (`edit-tag`) also need the action token `T` from `GET token`; the client fetches it once per client object.
- `stream/items/ids?s=user/-/state/com.google/reading-list&xt=user/-/state/com.google/read&n=<page>&c=<continuation>` returns `itemRefs` with decimal IDs (the same numbers as Fever's) and a `continuation` while more remain.
- `POST stream/items/contents` with repeated `i=<id>` fields returns `items` whose `id` is the long form `tag:google.com,2005:reader/item/<16 hex digits>`; FreshRSS removes its decimal `frss:id` from this response. `GReaderClient.hexToDecimal` converts exactly with string arithmetic, because IDs can exceed 2^53.
- In `compat` mode (used for these responses) the article body is `summary.content`; the feed is `origin.streamId` (`feed/<id>`); the link is `canonical[1].href`; read state is the category `user/-/state/com.google/read`. Titles get the same full-width `& < >` substitution as Fever.
- `POST edit-tag` with `T`, `a=user/-/state/com.google/read` and repeated `i` marks many items read in one request.
- `subscription/list?output=json` returns each feed with its category as a label; the label name is used as the group ID.
- Other servers (Miniflux, The Old Reader and others) implement the same API at their own base URL; `GReaderClient.findEndpoint` tries `<server>/api/greader.php` and then `<server>`. Only FreshRSS's behaviour has been checked against source.

## Checks before pushing

Run from the repository root:

```sh
luacheck kofever.koplugin tests
KOREADER_BASE=/path/to/koreader-base luajit tests/run_tests.lua
```

Tests need LuaJIT, `dkjson` (`lua-dkjson` on Debian/Ubuntu) and a checkout of koreader-base for `ffi/sha2.lua`. CI pins koreader-base to a fixed commit and sparse-checks out only that file.

The tests cover the client parsing (through a fake server), the sync algorithm, the store, the cache limit, categories and HTML conversion. They do not exercise the UI in `main.lua` or real networking, so UI changes should be read carefully against the KOReader source and, ideally, tried on a device or the KOReader desktop emulator. When you add behaviour to the client, sync, store or HTML modules, add checks to `tests/run_tests.lua` (the fake server in that file mirrors FreshRSS's responses; extend it when you use a new endpoint).

## Conventions

- Lua style follows KOReader: 4-space indentation, `local` everything, `Module:extend{}` / `Module:new{}` objects, `logger.warn`/`logger.info` with a `KOFever:` prefix.
- Never show a raw Lua error to the user. Wrap network calls and the sync in `pcall`, log the detail, and show a short `InfoMessage`.
- Never log the API key, the Google Reader auth or action token, request headers or the request body. `kofever_http.lua` logs only the method and URL; keep credentials out of URLs.
- Keep `local version = "dev"` in `_meta.lua` exactly as is; CI fails if it changes, because the release workflow replaces that line.
- Keep the README in step with user-visible changes (menu items, behaviour, files).
- Work on a branch and open a pull request against `main`; CI must pass before merging.

## Releasing

Publish a GitHub release with a tag such as `v1.2.0` (letters, digits, `.`, `_` and `-` only). The release workflow stamps the tag into `_meta.lua`, builds `KOFever-<tag>.zip` containing the `kofever.koplugin` folder, and attaches it to the release.
