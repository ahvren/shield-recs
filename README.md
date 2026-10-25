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
- `services`: badge color plus Android TV package per service. `Crunchyroll` was added (`com.crunchyroll.crunchyroid`).
- `generated`, `region`, `availability_source`, `availability_note`, `schema`: metadata.

Deploy: `curl -fsSLO <raw-url-of>/deploy.sh && sudo REPO_URL=https://github.com/ahvren/shield-recs.git bash deploy.sh`
Preview a local copy: `python3 -m http.server 8088`, then open http://localhost:8088/

## News feed (`news.json`)

There's a separate personalized news feed for the Shield UI's News view. It's independent of `recs.json`, which it never touches. Raw URL: `https://raw.githubusercontent.com/ahvren/shield-recs/main/news.json`

| File | Written by | Purpose |
|---|---|---|
| `news.json` | recommender (Grok Bot) | 25–40 items from roughly the last 48 h, grouped by topic |
| `news_prefs.json` | recommender only | Topic weights, muted topics and sources, boosted/excluded terms. The CT reads it but never writes it. |
| `feedback/news_feedback.jsonl` | Shield CT (append-only) | One JSON object per line per user action |
| `feedback/news_processed.json` | recommender | `{"processed_ids": [...]}`: feedback event ids already folded into prefs |
| `CURSOR_NEWS_PROMPT.md` | — | Prompt for the Cursor agent on the CT that builds the News view and feedback push |

**news.json keys**

- `version`: currently 1.
- `generated`: ISO UTC.
- `window_hours`: 48.
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
