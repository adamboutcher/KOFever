# KOFever

A KOReader plugin that syncs unread articles from a FreshRSS server using the Fever API, so they can be read offline on a Kindle (or any KOReader device). Articles opened offline are marked read on the server at the next sync.

## Installation

1. Enable the Fever API in FreshRSS and set an API password (FreshRSS: Settings > Profile > API management). This is separate from your normal login password.
2. Connect the Kindle by USB.
3. Copy the `kofever.koplugin` folder into `koreader/plugins/` on the device (usually `/mnt/us/koreader/plugins/`).
4. Eject and restart KOReader.

## Usage

The plugin adds a **KOFever** entry to the Tools menu with three items:

- **Server login**: enter the server URL (for example `https://rss.example.com`), your FreshRSS username and the API password. Only the Fever API key (MD5 of `username:apipassword`) is stored; the password itself is never saved. If the device is online, the login is checked straight away.
- **Sync now**: turns Wi-Fi on if needed, sends any reads queued offline, then downloads unread articles.
- **Browse unread articles**: lists cached unread articles, newest first, with the feed name on the right. Tap an article to read it as plain text.

Opening an article hides it from the list and queues it to be marked read on the server. The article stays in the cache until the server confirms the read, so it can be reopened offline in the meantime (set `SHOW_OPENED_ARTICLES = true` in `main.lua` to keep opened articles visible in the list with a "(read)" marker).

## Behaviour

- At most 200 articles are cached (`MAX_CACHED_ITEMS` in `main.lua`). When there are more unread articles on the server, the newest are downloaded and the sync summary reports how many were skipped.
- Articles are fetched in batches of 50, which is the FreshRSS per-request maximum.
- A failed sync never deletes cached articles or queued reads. A failed batch is retried on the next sync.
- Only HTTPS server URLs are accepted. If you leave out the scheme, `https://` is added.
- Changing the server URL clears the local cache and any queued reads, since article IDs belong to the old server.
- Images are not shown. Image alt text, where present, is shown as `[Image: ...]`.

## Files

| File | Purpose |
|---|---|
| `kofever.koplugin/_meta.lua` | Plugin name and description shown by KOReader |
| `kofever.koplugin/main.lua` | Menu entries, login dialog, article list and viewer |
| `kofever.koplugin/kofever_client.lua` | Fever API client (no UI code) |
| `kofever.koplugin/kofever_sync.lua` | Sync algorithm (no UI or HTTP code) |
| `kofever.koplugin/kofever_store.lua` | Local cache stored with `LuaSettings` |
| `kofever.koplugin/kofever_html.lua` | HTML to plain text conversion |
| `tests/run_tests.lua` | Offline test harness with a simulated FreshRSS server |

Settings and cache are stored in KOReader's settings directory as `kofever_settings.lua` and `kofever_cache.lua`. Errors are written to KOReader's log (`crash.log`) with a `KOFever:` prefix.

## Running the tests

The tests stub the KOReader modules and simulate the FreshRSS Fever endpoint, so they run on a desktop without KOReader. They need LuaJIT, `dkjson` (the `lua-dkjson` package on Debian/Ubuntu) and a checkout of [koreader-base](https://github.com/koreader/koreader-base) for `ffi/sha2.lua`.

```sh
KOREADER_BASE=/path/to/koreader-base luajit tests/run_tests.lua
```

The tests cover the sync algorithm, cache limit, offline read queue and HTML conversion. They do not exercise the KOReader UI or real network code, so the device testing steps in the plan still apply.
