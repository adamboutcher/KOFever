# Future plans

Ideas that have been researched but not built yet. Each entry should be read together with `README.md` and `AGENTS.md`, and should be turned into code through the usual branch and pull request process.

Statements are labelled so the implementer knows what to check:

- **[Verified]**: checked against source code while writing this plan.
- **[Verify]**: believed correct but not checked. Confirm before relying on it.
- **[Guess]**: plausible but unconfirmed. Expect to adjust.

---

## 1. Fetch the full article

Status: not started.

### 1.1 Problem

Many feeds, for example BBC News, only publish a short summary, so KOFever shows a sentence or two instead of the article.

- The Fever API gives each item a single `html` field holding whatever FreshRSS stored from the feed. There is no separate full-text field and no request asking FreshRSS to fetch the full page. [Verified: FreshRSS `p/api/fever.php`, `getItems()` returns `id, feed_id, title, author, html, url, is_saved, is_read, created_on_time`.]
- Other apps work around this on the client. Capy Reader's "full content" action downloads the article's own web page (`ArticleContent.fetch(article.url)` with browser-like headers) and extracts the main text on the phone with a bundled Mercury parser (`MercuryParser.fetch`), adding the lead image. It does not go through FreshRSS. [Verified: `jocmp/capyreader`, `capy/src/main/java/com/jocmp/capy/Account.kt` and `capy/src/main/java/com/jocmp/capy/articles/`.]

### 1.2 Alternative that needs no code

FreshRSS can fetch full text itself, per feed, from a CSS selector for the article body on the original site, found in the feed's settings under the advanced options. [Verify: exact option name and location in the installed FreshRSS version.] FreshRSS then stores the full text and every client, KOFever included, receives it with no extra download on the Kindle. It generally only applies to articles fetched after it is switched on. [Guess.]

Document this in the README whatever happens with the plugin feature, since it is the better option when the user controls the FreshRSS server.

### 1.3 Proposed feature

A **Full article** button in the article viewer:

1. Shown on the viewer's button row when the article has a URL and its text is not already the full version.
2. Tapping it runs through `NetworkMgr:runWhenOnline`, downloads the article's URL, extracts the main text, converts it to plain text with the existing `kofever_html.lua`, and shows it in place of the summary.
3. The full text is saved to the cache, replacing the summary, so it stays readable offline. The article is flagged so the button changes to **Summary** (to switch back) or disappears.
4. On any failure (no URL, network error, HTTP error, nothing extractable) show a short message and keep the summary.

Possible later extension, not part of the first version: a per-feed "always fetch full article during sync" setting, capped per sync, for feeds the user always wants in full.

### 1.4 Design

Keep the boundaries from `AGENTS.md`:

- **HTTP**: add a generic page fetch to `kofever_client.lua` (or a small `kofever_web.lua` if the client should stay Fever-only), returning `true, html, final_url` or `false, err` with the existing error kinds. No UI.
  - GET with a browser-like `User-Agent`; some sites refuse unknown agents. [Guess.]
  - Do not send `Accept-Encoding: gzip`; LuaSocket does not decompress. [Verify.]
  - Follow redirects, including http to https. KOReader's News Downloader handles redirects itself in `getUrlContent` rather than trusting LuaSocket's built-in redirect handling. [Verified: `plugins/newsdownloader.koplugin/epubdownloadbackend.lua`.] Copy that approach and cap the number of hops.
  - URL-encode the path the way `getUrlContent` does (`util.urlEncode(path, "/%%")`). [Verified.]
  - Use `socketutil:set_timeout` and `socketutil.table_sink` as the Fever client does, with the file-download timeouts, and cap the body size (for example 2 MB) to protect the Kindle's memory. [Size is a Guess.]
  - Consider `Trapper:dismissableRunInSubprocess` so the user can cancel a slow download, as News Downloader does. [Verified: used in `EpubDownloadBackend:loadPage`.]
- **Extraction**: a new `kofever_extract.lua` that takes page HTML and returns the main article HTML, or nil. No HTTP, no UI.
  - KOReader ships an HTML parser with CSS selectors, `require("htmlparser")`, used by News Downloader's `reduceHTML`. [Verified.] Using it ties the module to KOReader; either stub it in tests or keep a plain-Lua fallback. Decide when implementing.
  - Heuristic, in order: a known per-site selector table (start small, e.g. BBC); `<article>`; `[itemprop=articleBody]`; `<main>` or `[role=main]`; otherwise the element whose direct `<p>` children hold the most text. Drop `script`, `style`, `nav`, `header`, `footer`, `aside`, `form`, `figure` captions and share or related-links blocks first.
  - Reject results shorter than the existing summary or below a minimum length (for example 500 characters) as a failed extraction. [Threshold is a Guess.]
  - Expect good results on mainstream news sites and weaker results on unusual layouts. [Guess; measure on real pages.]
  - Character sets: assume UTF-8. Pages declaring another charset (for example ISO-8859-1) need converting or should be rejected with a message. [Verify what KOReader offers for conversion.]
- **Store**: `kofever_store.lua` gains a way to replace an article's text and mark it full (for example an item field `full = true`).
  - If switching back to the summary is wanted, keep the original as a second file (for example `<id>.summary.txt`). `Store:load`'s orphan clean-up, `removeItem` and `clear` must then handle both files, to keep invariant 5 in `AGENTS.md`.
  - Full text is larger; the cache size setting counts articles, not bytes, so a large cache of full articles uses more storage. Note this in the README. [Guess at typical size: tens of KB of plain text per article.]
- **UI** (`main.lua`): the extra button in the viewer's `buttons_table`, a progress message while downloading (with `UIManager:forceRePaint()`), and re-opening the viewer on the same article with the new text. All user-visible strings wrapped in `_()`.

### 1.5 Tests

- Extraction: add HTML fixtures under `tests/fixtures/` (a saved BBC article page, a blog post, a page with no clear article, a page with only navigation) and check the extracted text in `tests/run_tests.lua`. Saved pages are third-party content; keep them small and trimmed, or write synthetic pages that mimic the structure.
- Fetch: extend the fake HTTP layer in the test harness to serve pages, redirects (including http to https), errors and oversized bodies.
- Store: replacing text, the `full` flag, switching back, and clean-up of any second file.

### 1.6 Open questions

- Should fetching mark anything on the server? It should not; the article is already marked read when opened. Keep invariant 3.
- Should images be kept? Not in this version; the plugin shows plain text only.
- Per-site selector table: hard-coded in the plugin, or user-editable? Start hard-coded.

### 1.7 Acceptance criteria

1. On a summary-only feed (for example BBC News), tapping **Full article** with Wi-Fi on replaces the summary with the full article text.
2. The full text stays available after closing the viewer, restarting KOReader and turning Wi-Fi off.
3. Failures leave the summary in place and show a short message; KOReader never crashes or shows a raw Lua error.
4. Invariants 1 to 6 in `AGENTS.md` still hold, and the new code paths have tests.
5. README documents the button and the FreshRSS per-feed alternative.

---

## 2. Star articles

Status: not started.

### 2.1 Idea

A **Star** button in the article viewer. Tapping it keeps the article on the device and stars it on FreshRSS, the same way reads are queued offline and sent at the next sync. A starred article stays cached after it is read, and is shown in a **Starred** entry in the category list.

### 2.2 What the servers offer

- **Fever**: [Verified: FreshRSS `p/api/fever.php`]
  - `mark=item&as=saved&id=<id>` stars an item and `as=unsaved` removes the star. FreshRSS also accepts `with_ids=<comma separated ids>` instead of `id` to do several at once. [Verified, but this is not in the Fever spec, so other servers may not support it.]
  - `?api&saved_item_ids` returns the IDs of all starred items.
  - Each item from `items` already carries `is_saved` (0 or 1). KOFever currently ignores it.
- **Google Reader**: [Verified: FreshRSS `p/api/greader.php`]
  - `POST edit-tag` with `T`, `a=user/-/state/com.google/starred` (or `r=` to remove) and repeated `i` fields. This is the call `markReadMany` already uses, with a different tag, and it handles many items in one request.
  - `stream/items/ids?s=user/-/state/com.google/starred` lists starred item IDs, paged with the continuation token like the unread list.
  - Items from `stream/items/contents` list `user/-/state/com.google/starred` in `categories` when starred (`app/Models/Entry.php`, `toGReader`). [Verified]
- Other Google Reader servers (Miniflux, The Old Reader and others) probably behave the same way. [Guess]

### 2.3 Proposed behaviour

1. **Star button** in the viewer's `buttons_table`, showing **Star** or **Unstar** depending on the current state. The change is applied locally straight away and queued for the server.
2. **Offline queue**: a new `pending_stars` table in the cache index, mapping article ID to the wanted state (`true` or `false`). A later toggle of the same article replaces the earlier one, so only the final state is sent.
3. **Sync**: push `pending_stars` right after `pending_reads`. The clients get `markStarred(id, starred)` and an optional `markStarredMany(ids, starred)`, following the existing `markRead` and `markReadMany` pattern. Entries stay queued on failure.
4. **Pull stars from the server**: fetch the starred IDs at sync, download any starred article not yet cached, and update the `starred` flag on cached articles, so stars set in the FreshRSS web interface appear on the device. A local change still waiting in `pending_stars` wins over the server until it has been sent.
5. **Starred view**: a **Starred** entry in the category list, shown only when at least one article is starred, listing starred articles newest first. The usual viewer, Previous and Next buttons work from it.
6. **Cache rules**: starred articles are not removed by the cache limit or by pruning, even when read, and do not count toward the cache size. Unstarring makes the article ordinary again, so it is pruned at the next sync if it is read. Clear cache removes starred articles and pending stars too, with the confirmation text updated to say so.

### 2.4 Design

- Keep the client interface additive: `getStarredIds` (decimal ID strings), `markStarred`, optional `markStarredMany`. Update the interface list in `AGENTS.md`.
- Both clients must return an error rather than a partial starred list, as they must for unread IDs. Pruning of the starred flag depends on the list being complete.
- Store: an item field `starred`, `Store:setStarred(id, bool)`, and the `pending_stars` table. `Store:applyLimit` and the sync pruning step skip starred items. Add a new invariant to `AGENTS.md`: a star queued in `pending_stars` is never dropped until the server accepts it.
- Review invariant 4 in `AGENTS.md` (the cache limit drops read articles first): starred articles are now exempt.
- Fever `getItems` and the Google Reader item conversion fill in `is_starred` (Fever shape gains one field alongside `is_read`).
- No change to the rule that nothing is marked on the server except through the client for IDs in the pending tables.

### 2.5 Tests

- Fake Fever and Google Reader servers gain starred state, `saved_item_ids`, the starred stream and `edit-tag` with the starred tag.
- Star while offline, then sync: the server shows the star and the queue is empty.
- Star on the server, then sync: the article is downloaded and shown as starred.
- Failed push keeps the queue; a toggle replaces an earlier queued state.
- A starred article survives the cache limit and pruning; unstarring a read article lets the next sync prune it.
- Clear cache empties stars and the queue.

### 2.6 Open questions

- Should starred articles count toward the cache size? The plan says no, so a user who stars many articles can use more storage than the setting suggests. Reconsider if the starred set grows large. [Guess]
- Should stars fetched from the server be capped on the first sync? A large starred history would otherwise be downloaded in full. A separate cap, for example the newest 200 starred articles, is one option. [Guess]
- Fever servers other than FreshRSS may not accept `with_ids` for marking, so the Fever client should fall back to one request per item when the batched call fails. [Verify]

### 2.7 Acceptance criteria

1. Starring an article offline shows it as starred on the device and on FreshRSS after the next sync.
2. A star added or removed in the FreshRSS web interface appears on the device after the next sync.
3. Starred articles survive reading, the cache limit and pruning until they are unstarred.
4. A failed or interrupted sync never loses a queued star.
5. Invariants 1 to 6 in `AGENTS.md` still hold, with the new star invariant added, and the new code paths have tests.
6. README documents the button, the Starred view and the cache behaviour.
