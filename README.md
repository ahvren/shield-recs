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
