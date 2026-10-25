# shield-recs

A TV-friendly recommendations page for the NVIDIA Shield. Static files only:
- `index.html`: the glass-tile UI. It loads `recs.json` at runtime and re-checks it every 30 min. Use it over HTTP; `file://` won't work.
- `recs.json`: the data (rows > items: title, year, type, services, links, poster, why, synopsis, genres, imdb, tmdb, justwatch). Regenerate this file plus `posters/` to update the list. The HTML never changes.
- `posters/`: local poster JPGs (from JustWatch's image CDN), referenced by relative path.
- `deploy.sh`: VM setup (clone, nginx or docker nginx:alpine on :8088, and a systemd timer for git pull every 30 min). Idempotent.
- `CURSOR_PROMPT.md`: the same setup, as a prompt for a Cursor agent on the VM.
- `SHIELD.md`: how to open the page full screen on the Shield.

## recs.json keys
- `rows` (unchanged): array of `{label, items[]}`, currently Movies and Shows.
- `anime` (new, Oct 25 2026): **one object with the same shape as a single `rows[]` entry**, `{"label": "Anime", "items": [...]}`. Items use the same fields as `rows[].items[]` (title, year, type, services, links, poster, why, synopsis, genres, imdb, tmdb, justwatch). `type` is `"show"` for these series. It's a separate top-level key, so readers that only know `rows` keep working. `index.html` draws it as the third row after `rows`.
- `services`: badge color plus Android TV package per service. `Crunchyroll` was added (`com.crunchyroll.crunchyroid`). `Hulu` was added on Oct 25 2026 (`com.hulu.livingroomplus`, unverified; links are `https://www.hulu.com/watch/<id>`). Hulu-only titles are allowed again.
- `generated`, `region`, `availability_source`, `availability_note`, `schema`: metadata.

Deploy: `curl -fsSLO <raw-url-of>/deploy.sh && sudo REPO_URL=https://github.com/ahvren/shield-recs.git bash deploy.sh`
Preview a local copy: `python3 -m http.server 8088`, then open http://localhost:8088/

## News feed (`news.json`)

There's a separate personalized news feed for the Shield UI's News view. It's independent of `recs.json`, which it never touches. Raw URL: `https://raw.githubusercontent.com/ahvren/shield-recs/main/news.json`

| File | Written by | Purpose |
|---|---|---|
| `news.json` | recommender (Grok Bot) | 100–150 items from the last 48 h, extended to 72 h when a topic needs filling, grouped by topic |
| `news_prefs.json` | recommender only | Topic weights, muted topics and sources, boosted/excluded terms. The CT reads it but never writes it. |
| `feedback/news_feedback.jsonl` | Shield CT (append-only) | One JSON object per line per user action |
| `feedback/news_processed.json` | recommender | `{"processed_ids": [...]}`: feedback event ids already folded into prefs |
| `CURSOR_NEWS_PROMPT.md` | — | Prompt for the Cursor agent on the CT that builds the News view and feedback push |

**news.json keys**

- `version`: currently 1.
- `generated`: ISO UTC.
- `window_hours`: the maximum item age, currently 72. Items prefer the last 48 h, and the 48–72 h range only fills topic quotas.
- `topics[]`: `{id, label, count}`, in display order. The ids are `homelab`, `gaming`, `aviation`, `streaming`, `ai`, and `local`.
- `items[]`, sorted by `score` descending, with these fields:
  - `id`: the first 16 hex characters of sha256(url). It stays the same across regenerations.
  - `topic`, `title`, `source`, `url`
  - `published`: ISO UTC.
  - `summary`: 1–2 sentences, written by the recommender.
  - `image`: optional, hotlinked from the publisher (og:image).
  - `score`: 0–1, where 0.7 × relevance + 0.3 × freshness.

**Feedback line** (`feedback/news_feedback.jsonl`):

```json
{"id":"<uuid4>","ts":"2026-10-25T10:00:00Z","item_id":"<news id>","topic":"homelab","source":"Phoronix","title":"...","action":"up|down|hide_topic|hide_source|more_like_this"}
```

The CT pushes these lines with the GitHub Contents API. It GETs the file's sha, then PUTs the full content with the new lines appended, retrying on 409/422. Events wait in a local queue with backoff, and the token is read from `/etc/shield-recs/github_token`. The CT writes only this path. On each refresh, the recommender:

1. Reads any new event ids.
2. Updates `news_prefs.json` (weights, mutes).
3. Records the ids in `feedback/news_processed.json`.
4. Regenerates `news.json`.

## Mobile news page (`/m/`, a Google Discover replacement)

**Live:** https://ahvren.github.io/shield-recs/m/ (GitHub Pages, built from `main`, root folder)

This is an installable PWA for Chris's Galaxy phone. Open the link in Chrome, then use ⋮ → **Add to Home screen / Install app**. It runs standalone with a dark theme.

| File | Purpose |
|---|---|
| `m/index.html` | The whole app, with no build step and no dependencies |
| `m/manifest.webmanifest` | PWA manifest (standalone, `#07080c`, scope `./`) |
| `m/sw.js` | Service worker |
| `m/icons/` | 192, 512, maskable 512, Apple touch 180 and favicon 32 |
| `m-preview.png` | Headless Chrome render at 412×915 |
| `.nojekyll` | Pages serves files as-is, with no Jekyll processing |

**How it works**

- **Data:** loads `../news.json` and `../recs.json` at runtime with relative paths, so it reads the same files the Shield/CT use.
- **Caching:** the service worker serves the app shell from cache first. The JSON is network-first with a cache fallback, so a stale feed shows when offline, along with an "Offline" banner. Article images get an opportunistic cache of about 120 entries.
- **News tab:** a Discover-style vertical feed of image, topic, source, relative time, title and summary.
  - Topic chips sit at the top; "For you" shows everything, ranked by score plus local boosts.
  - Pull to refresh, or use the ↻ button.
  - Tapping a card opens the article in a new tab.
- **Watch tab:** Movies, Shows and Anime from `recs.json`, with posters, the "why" text and service chips. Tapping opens the first service link.
- **Search engines:** `<meta name="robots" content="noindex,nofollow,noarchive">` is set on `/m/` and on the TV `index.html`.

**Feedback without a token (GitHub issues)**

Each card has five white line-icon buttons, all inline SVG with no emoji: thumbs-up (Up), thumbs-down (Down), plus (More like this), eye-off (Hide topic) and ban (Hide source). Each has an `aria-label`, and ≡ → Feed settings shows a legend. The feed renders 20 cards at a time as you scroll, with lazy-loaded images, so 150+ items stay smooth. Each action does two things:

1. Applies locally right away through `localStorage` (key `shieldnews.v1`), with a 5-second Undo:
   - Down hides the story.
   - Hide topic or Hide source hides everything matching.
   - Up and More like this add a check-icon badge and boost that topic and source in the ranking.
   - ≡ → Feed settings lists everything hidden and can unhide it, or reset all local tweaks.
2. Opens a prefilled new-issue page, `https://github.com/ahvren/shield-recs/issues/new?labels=news-feedback&title=…&body=…`.
   - The title is `news-feedback: <action> — <item title>`.
   - The body contains a fenced `json` block holding exactly one `feedback/news_feedback.jsonl`-shaped object: `{id, ts, item_id, topic, source, title, action}`.
   - Chris only taps **Submit new issue**.

**Batch mode** (the Batch button): actions queue locally instead. **Send N actions in one issue** then opens a single issue titled `news-feedback: batch — N actions`, whose body holds a JSON **array** of those objects. URLs are kept under about 7.6 KB; anything over that stays queued for the next send.

**Labels:** `news-feedback` is used now. `recs-feedback` is reserved for a future Watch-tab feedback flow.

**Recommender side:**

1. Read open issues labelled `news-feedback`: `gh issue list -R ahvren/shield-recs -l news-feedback --state open --json number,body`.
2. Parse the JSON block (an object or an array).
3. De-duplicate by event `id` against `feedback/news_processed.json`, using the same `processed_ids` list as the CT's jsonl events.
4. Apply the events to `news_prefs.json`.
5. Close each issue with a comment.

**Pages and raw URLs:** Pages is a separate deployment and changes nothing at `raw.githubusercontent.com`, so the CT and VM keep using the raw URLs. Pages adds a CDN cache of about 10 minutes, and the app busts it with `?t=`.

### How news.json is built

The builder lives on the bot's box at `/workspace/newswork/` and isn't part of this repo. It has three pieces:

- `build_news.py` (v2): the pipeline.
- `news_sources.py`: the config, covering feeds, keyword weights, gates and caps.
- `curated.json`: hand-written summaries that override feed text.

`python3 build_news.py` runs in about 1–1.5 minutes:

1. Fetches about 80 RSS/Atom feeds in parallel, using ETag/Last-Modified caching.
2. Scrapes two HTML listings that have no working feed: the FAA newsroom and AIN.
3. Pulls official Steam announcements for about 25 tracked survival, crafting and co-op games.
4. Scores keyword relevance per topic. Gated feeds must hit a topic keyword. There are penalties for deals, clickbait and Star Wars, and `news_prefs.json` weights, mutes, boosts and excluded terms apply.
5. Removes near-duplicate stories and caps any one game or subject at 2 items.
6. Fills a per-topic quota, `target_items[1] / topics` (25 each by default): first from the last 48 h, then up to 72 h. Each source has a cap.
7. Backfills missing images and short summaries from each article's og: tags, cached for 7 days.
8. Builds longer summaries of about 500–700 characters, cut at a sentence boundary. It uses the longest feed text (summary or content:encoded) after stripping boilerplate such as "appeared first on", Read more, image credits and Steam bbcode. For feed stubs under about 260 characters, it reads the first paragraphs of the article page (7 s timeout, cached 7 days, failures retried after a day, never fatal). Hand-written curated summaries stay first, with new sentences from the article appended after them. The phone page clamps this text and offers a More/Less toggle.

Lower-ranked items use the publisher's own description, trimmed to 2 sentences. Curated items keep their hand-written summaries.
