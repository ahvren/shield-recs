# shield-recs

A TV-friendly recommendations page for the NVIDIA Shield. Static files only:
- `index.html`: the glass-tile UI. It loads `recs.json` at runtime and re-checks it every 30 min. Use it over HTTP; `file://` won't work.
- `recs.json`: the data (rows > items: title, year, type, services, links, poster, why, synopsis, genres, imdb, tmdb, justwatch). Regenerate this file plus `posters/` to update the list. The HTML never changes.
- `posters/`: local poster JPGs (from JustWatch's image CDN), referenced by relative path.
- `deploy.sh`: VM setup (clone, nginx or docker nginx:alpine on :8088, and a systemd timer for git pull every 30 min). Idempotent.
- `CURSOR_PROMPT.md`: the same setup, as a prompt for a Cursor agent on the VM.
- `SHIELD.md`: how to open the page full screen on the Shield.

Deploy: `curl -fsSLO <raw-url-of>/deploy.sh && sudo REPO_URL=https://github.com/ahvren/shield-recs.git bash deploy.sh`
Preview a local copy: `python3 -m http.server 8088`, then open http://localhost:8088/
