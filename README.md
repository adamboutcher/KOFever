# KOFever

A KOReader plugin that syncs unread articles from a FreshRSS server using the Fever API, so they can be read offline on a Kindle (or any KOReader device). Articles opened offline are marked read on the server at the next sync.

## Installation

1. Enable the Fever API in FreshRSS and set an API password (FreshRSS: Settings > Profile > API management). This is separate from your normal login password.
2. Download `KOFever-<version>.zip` from the latest [release](https://github.com/adamboutcher/KOFever/releases) and extract it. It contains the `kofever.koplugin` folder.
3. Connect the Kindle by USB.
4. Copy the `kofever.koplugin` folder into `koreader/plugins/` on the device (usually `/mnt/us/koreader/plugins/`). When updating, replace the old folder; your settings and cached articles are kept, since they live in KOReader's settings directory.
5. Eject and restart KOReader.

The installed version is shown in the plugin's description under Tools > More tools > Plugin management (`dev` for copies taken straight from the repository).

## Usage

The plugin adds a **KOFever** entry to the Tools menu with these items:

- **Server login**: enter the server URL (for example `https://rss.example.com`), your FreshRSS username and the API password. Only the Fever API key (MD5 of `username:apipassword`) is stored; the password itself is never saved. If the device is online, the login is checked straight away.
- **Sync now**: turns Wi-Fi on if needed, sends any reads queued offline, then downloads unread articles.
- **Browse unread articles** (or **Browse articles** when read articles are shown): shows your FreshRSS categories with the number of unread articles in each, plus an **All articles** entry at the top. Tap a category to list its articles, newest first, with the feed name on the right; tap an article to read it as plain text. The back arrow, the close button or the Back key returns to the category list. Articles from feeds without a category are under **Uncategorised**. If all cached articles are in one category, the category list is skipped.
- **Show read articles**: a checkbox, off by default. See below.
- **Cache size**: how many articles are kept on the device, from 50 to 3000 in steps of 50 (default 200). Hold the arrows to change it by 500 at a time. Lowering it removes articles straight away: read ones first, then the oldest unread ones.

Opening an article queues it to be marked read on the server.

- With **Show read articles** off, an opened article disappears from the list. It stays in the cache until the server confirms the read, so it is not lost if the read has not been sent yet, and is removed at the next successful sync.
- With **Show read articles** on, read articles stay in the list. Unread titles are shown in bold and read titles in normal weight. Articles read on the server (for example in the FreshRSS web interface) are also kept and shown as read. Read articles stay cached until the cache limit needs the space; when it does, read articles are removed before unread ones. If you have more unread articles on the server than the cache limit, read articles will therefore be removed at the next sync.

## Behaviour

- At most **Cache size** articles are cached. When there are more unread articles on the server, the newest are downloaded and the sync summary reports how many were skipped. A large cache makes the first sync longer, since articles are downloaded 50 at a time.
- Articles are fetched in batches of 50, which is the FreshRSS per-request maximum.
- A failed sync never deletes cached articles or queued reads. A failed batch is retried on the next sync.
- Both `https://` and `http://` server URLs are accepted. If you leave out the scheme, `https://` is added. With `http://` the API key and articles are sent unencrypted, and the login check says so.
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

Settings and the cache index are stored in KOReader's settings directory as `kofever_settings.lua` and `kofever_cache.lua`. Article text is stored separately, one file per article, in the `kofever_articles` folder next to them, so the index stays small even with a large cache. Caches from earlier versions, which kept the text in the index, are converted automatically. Errors are written to KOReader's log (`crash.log`) with a `KOFever:` prefix.

## Running the tests

The tests stub the KOReader modules and simulate the FreshRSS Fever endpoint, so they run on a desktop without KOReader. They need LuaJIT, `dkjson` (the `lua-dkjson` package on Debian/Ubuntu) and a checkout of [koreader-base](https://github.com/koreader/koreader-base) for `ffi/sha2.lua`.

```sh
KOREADER_BASE=/path/to/koreader-base luajit tests/run_tests.lua
```

The tests cover the sync algorithm, cache limit, offline read queue and HTML conversion. They do not exercise the KOReader UI or real network code, so the device testing steps in the plan still apply.

## Releases

Publishing a GitHub release runs `.github/workflows/release.yml`, which stamps the release tag into `_meta.lua`, zips the `kofever.koplugin` folder as `KOFever-<tag>.zip` and attaches it to the release. Tags may only contain letters, digits, `.`, `_` and `-` (for example `v1.0.0`).

## Continuous integration

Lint and the tests run on GitHub Actions for every pull request and every push to `main` (`.github/workflows/ci.yml`). To lint locally, run `luacheck kofever.koplugin tests` from the repository root.
