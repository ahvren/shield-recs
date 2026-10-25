# Cursor prompt: add a News view to the Shield recs UI (runs on the Proxmox CT)

Paste everything below the line into the Cursor agent on the CT that already serves the Shield recs UI and pushes recs feedback.

---

You are working on the CT that serves the Shield TV recommendations UI and already pushes recs feedback to GitHub (repo `ahvren/shield-recs`, branch `main`). Add a **News** view to that UI. Every step must be idempotent, so it is safe to re-run this whole prompt.

## 0. Ground rules (do not break these)

- **Do not modify `recs.json`, `news.json`, `news_prefs.json`, or the existing recs feedback files.** The recommender (Grok Bot) owns them.
- The only repo path this CT may write for news is **`feedback/news_feedback.jsonl`**. Do not create commits that touch any other path.
- The GitHub token lives at **`/etc/shield-recs/github_token`** (reuse the file the recs feedback already uses). Read it at request time. Never log it, never echo it, never copy it into the repo, an env file under version control, the browser, or client-side JS. Keep the file at mode 0600, owned by the service user.
- Reuse the existing recs-feedback push code (Contents API + local queue + retry) wherever you can instead of writing a second implementation. Parameterize the target path.
- Keep the existing Recs/Anime rows working exactly as they do now.

## 1. Data source

- Feed: `https://raw.githubusercontent.com/ahvren/shield-recs/main/news.json`
- Prefs (read-only, optional): `https://raw.githubusercontent.com/ahvren/shield-recs/main/news_prefs.json`
- Pull both **every 30 minutes** on the backend (systemd timer or the scheduler you already use for recs). Send `If-None-Match` with the last ETag and treat a 304 as "no change". Cache the last good copy on disk (for example `/var/lib/shield-recs/news.json`) and serve that to the UI, so the TV still works when GitHub is unreachable. If a download fails to parse as JSON, keep the previous cache.
- raw.githubusercontent.com caches for about 5 minutes, so a fresh commit can take that long to appear. That's expected.

### news.json shape (v1)

```json
{
  "version": 1,
  "generated": "2026-10-25T09:40:00Z",
  "window_hours": 72,
  "topics": [{"id": "homelab", "label": "Homelab & self-hosting", "count": 7}],
  "items": [{
    "id": "16-hex sha256(url) prefix, stable",
    "topic": "homelab",
    "title": "...",
    "source": "Phoronix",
    "url": "https://...",
    "published": "2026-10-24T18:00:00Z",
    "summary": "1-2 sentences",
    "image": "https://... (optional, may be missing)",
    "score": 0.83
  }]
}
```

- Topic ids are `homelab`, `gaming`, `aviation`, `streaming`, `ai`, and `local`. Render topics in the order of `topics[]` and use `label` as the row heading. Within a topic, sort by `score` descending.
- Ignore unknown fields, and tolerate a missing `image`. A topic id the UI hasn't seen before should still render as a row, using its label.
- If `news_prefs.json` exists, hide `muted_topics` and `muted_sources` too. Normally the recommender has already applied them to news.json, so this is just a safety net.

## 2. UI: News view

- Add a **News** entry next to the existing views (a top tab or a row header). Focus starts on the first card of the first topic.
- Each topic is one horizontal row of **glass cards**, in the same visual language as the recs UI: frosted background, rounded corners, and a large focus ring with a scale-up on focus. Design for 1920×1080 viewed from a couch. Minimum text size is about 24 px for titles and 20 px for meta.
- Each card shows:
  - The image (16:9, `object-fit: cover`). If there's no image or it fails to load, show a topic-colored gradient with the source name.
  - The title, clamped to 3 lines.
  - Source · relative age ("5 h ago"), computed from `published`.
  - The summary, clamped to 2–3 lines.
- **D-pad navigation**: left and right move within a row, up and down move between rows (remember the column per row), and Back closes overlays or returns to the previous view. Everything must be reachable without a pointer. Handle `ArrowUp/Down/Left/Right`, `Enter`, and `Escape`/`Backspace`/`GoBack` (keyCode 4 on Android WebView).
- **OK/Enter on a card** opens a detail overlay. It shows a big image, the full title and summary, the source and time, and the action buttons below. Navigate the buttons left and right:
  1. **Open article**: the default-focused button.
  2. **Up** (thumbs-up icon) → action `up`
  3. **Down** (thumbs-down icon) → action `down`
  4. **More like this** (plus icon) → action `more_like_this`
  5. **Hide topic** (eye-off icon) → action `hide_topic`
  6. **Hide source** (ban icon: a circle with a diagonal slash) → action `hide_source`
- **Icon style (match the phone page `m/index.html`)**: white icons as inline SVG (`viewBox="0 0 24 24"`, `stroke="currentColor"`, round caps and joins) sitting on **frosted-glass circular buttons**: background `rgba(255,255,255,.16)` with a backdrop blur and no border. The thumbs-up and thumbs-down icons are **solid** (`fill="currentColor"`, stroke-width about 1.2). Plus, eye-off and ban are line icons with a stroke-width of about 2.4. **No emoji and no colored glyphs anywhere in the UI**, including toasts, badges and empty states.
  - The idle state is a transparent button with a thin white border.
  - The focused state is a white fill with a dark icon, plus the usual focus ring.
  - The "done" state (already liked) is also a white fill with a dark icon.
  - Under the focused button, show the text label ("Hide source") in 20 px+ type, and give every button an `aria-label`.
  - Copy the SVG paths from `ICON` in `m/index.html` (they're Lucide-style: thumbs-up, thumbs-down, plus, eye-off, ban) so both screens match. Size them at about 36 px on the TV.
- Pressing OK twice on a card (once to open the overlay, once on the default button) opens the article.
- **Opening the article**: use an Android intent URL so the Shield hands off to a real browser, with a plain-URL fallback:

  ```
  intent://<url-without-scheme>#Intent;scheme=https;action=android.intent.action.VIEW;S.browser_fallback_url=<urlencoded url>;end
  ```

  - If the URL is `http:`, use `scheme=http`.
  - If the intent navigation throws or nothing happens within about 1.5 s, fall back to `window.open(url, "_blank")` or `location.href = url`.
  - In Fully Kiosk, the "Open URL Schemes in Other Apps" setting must be on, as it already is for the recs intents. Document this in the README section you add.
- After any feedback action, show a small toast ("Got it, fewer like this", "Hidden: <source>", and so on). Then **hide the affected items locally right away**:
  - `down` → hide that item.
  - `up` and `more_like_this` → keep the item, but mark it with a small badge: a white line check icon (SVG) plus the text "Liked" or "More like this". Use no emoji or ✓ character.
  - `hide_topic` → hide the whole topic row.
  - `hide_source` → hide every item from that source.
- Persist local hides in the backend's state (for example `/var/lib/shield-recs/news_local_state.json`), keyed by item id, topic, and source, so they survive reloads and TV restarts. Mirror them to `localStorage` only as a cache. Local topic and source hides stay in place until the recommender's next news.json no longer contains them. Prune entries for item ids absent from the current news.json once they're more than 7 days old.
- Add a small "Undo" option to the toast for 5 s. Undo removes the local hide and drops the queued event if it hasn't been pushed yet. If it was already pushed, leave it; the recommender will see a later contrary action.
- Show an empty state when every item is hidden or the feed is unavailable, like "No news right now, last updated <time>".
- Show "Updated <relative time>" in the view header, based on `generated`.

### Volume: 100–150 items must stay smooth

news.json now carries **100–150 items** (about 25 per topic, `window_hours` up to 72), and that may grow. The Shield's WebView is slow, so:

- **Render lazily per row.** Build DOM only for the cards in view plus about 6 on each side, either virtualizing or windowing each horizontal row. Append more as focus moves right. Don't create 150 cards at startup.
- **Render rows incrementally.** Render the first 2 topic rows immediately and the rest on `requestIdleCallback` or as focus moves down.
- **Load images lazily and small.** Use `loading="lazy"` and `decoding="async"`, and only set `src` for cards within about 1 screen of the focused one. Prefer the CT image proxy with resizing to about 480 px wide (WebP or JPEG, quality ~75) to keep decode and memory cost low. Cap the in-memory image count by clearing `src` for cards far off-screen.
- **Use cheap focus effects.** Animate only `transform` and `opacity` on focus changes. Avoid `backdrop-filter` on every card: use one blurred background layer and semi-opaque card fills instead.
- **Keep the parse cheap.** news.json is about 150–250 KB. Parse it once on the backend and serve `/api/news` with local hides applied, so the TV doesn't re-filter on every key press.
- **Allow an optional per-row cap.** Show the top N per topic (default 30, set in the config) with a "More" card at the end that loads the rest.

### Images

- Default: hotlink `image` directly, with `referrerpolicy="no-referrer"` and `loading="lazy"`.
- Optional (recommended): add a backend proxy route `GET /img?u=<urlencoded>`. It should:
  - Allow only `http`/`https` and refuse private and loopback IP ranges after DNS resolution (SSRF guard).
  - Cap responses at 5 MB and accept only `image/*` content types.
  - Cache to disk for 7 days. Resizing to about 640 px wide is optional.
  - Make the UI use it when `?imgproxy=1` or a config flag is set.
- Some publishers block hotlinking, and the proxy fixes that. Either way, a failed image must fall back to the gradient card.

## 3. Feedback: push to `feedback/news_feedback.jsonl`

Each user action appends **one JSON object per line** (compact, no pretty-printing, `\n`-terminated):

```json
{"id":"<uuid4>","ts":"2026-10-25T10:00:00Z","item_id":"<news item id>","topic":"homelab","source":"Phoronix","title":"<item title>","action":"up"}
```

- `action` ∈ `up | down | hide_topic | hide_source | more_like_this`. Other values are not allowed.
- `id` is a new UUIDv4 per event, so the recommender can de-duplicate. Never reuse it, and never rewrite or remove existing lines.
- `ts` is ISO-8601 UTC with `Z`, at second precision.
- For `hide_topic` and `hide_source`, still fill in item_id, topic, source, and title from the card the user acted on.

### Push algorithm (same as recs feedback)

1. Write the event to a **local durable queue** first, for example `/var/lib/shield-recs/news_feedback_queue.jsonl`, appended with fsync. The UI call returns success once the event is queued; don't make the TV wait on GitHub.
2. A background flusher runs when an event is queued, then every 60 s while the queue isn't empty, and at startup. It does this:
   - `GET https://api.github.com/repos/ahvren/shield-recs/contents/feedback/news_feedback.jsonl?ref=main` with headers `Authorization: Bearer <token>`, `Accept: application/vnd.github+json`, and `X-GitHub-Api-Version: 2022-11-28`. Decode the base64 `content` and keep the `sha`.
   - If the file is 404, create it: PUT without a `sha`.
   - Skip queued events whose `id` already appears in the remote file. That makes the flush idempotent after a crash between the PUT and the queue truncation.
   - Append the remaining events to the remote content. Make sure the existing content ends with `\n` before you append.
   - `PUT` the same URL with `{"message":"news feedback: +N action(s) from shield-home","content":"<base64 of new full content>","sha":"<sha from GET>","branch":"main"}`.
   - On **200/201**, remove the pushed events from the local queue. Rewrite the queue atomically with a temp file plus rename.
   - On **409 or 422** (sha mismatch, meaning someone else committed), re-GET and retry immediately, up to 5 times.
   - On **401/403**, stop retrying and surface a "feedback paused: token problem" status in the UI header and logs. Never log the token or the Authorization header.
   - On **5xx, network errors, or 429**, back off exponentially (5 s → 10 s → … capped at 15 min) with jitter, and honor `Retry-After`.
   - Batch everything queued into one commit per flush.
3. Writes must only ever target `feedback/news_feedback.jsonl`. Hard-code the path allowlist in the push function and refuse anything else.
4. A fine-grained PAT limited to this repo with **Contents: read/write** is enough. If the existing recs token already works, reuse it.

## 4. Backend endpoints (suggested)

- `GET /api/news`: the cached news.json, with local hides applied or a `hidden` flag added per item.
- `POST /api/news/feedback` `{item_id, action}`: the server fills in topic, source, and title from the cache, generates id and ts, queues the event, updates local state, and returns `{ok:true, queued:n}`.
- `POST /api/news/undo` `{event_id}`
- `GET /api/news/status`: last pull time, ETag, queue length, and last push result.
- `GET /img?u=`: the optional image proxy.

## 5. Tests / acceptance

- Load the News view in a desktop browser at 1920×1080. Walk every row and every overlay button using only arrow keys, Enter, and Escape.
- `curl` `/api/news/status` before and after a forced pull. A second pull should return 304 and leave the cache unchanged.
- Simulate an action offline: unplug the network or point at a bad host. The event should stay queued, the item should stay hidden after a reload, and the event should push once the network returns. Verify a single new line appears on GitHub with the correct schema, then validate it with `python3 -c 'import json,sys;[json.loads(l) for l in open(sys.argv[1])]' news_feedback.jsonl`.
- Simulate a 409: commit to the file from somewhere else between GET and PUT. The retry should succeed with no lost or duplicated lines.
- Confirm `git log --stat` on GitHub shows CT commits touching only `feedback/news_feedback.jsonl` (and the recs feedback file for recs actions).
- On the Shield (Fully Kiosk): OK on "Open article" should open the browser via the intent, and Back should return to the UI.

## 6. Docs

Add a short "News view" section to the CT's local README. Cover the files and paths above, the timer, the image proxy flag, the Fully Kiosk setting, and how to inspect or flush the queue manually.
