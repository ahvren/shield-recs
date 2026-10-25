# Cursor prompt: self-host the news + recs app on a Proxmox CT (move off GitHub Pages)

Paste everything below the line into a Cursor agent with a shell on the homelab CT that already serves the Shield UI and pulls `ahvren/shield-recs`. Run it on that same CT, or on a new CT on the same Proxmox host if you prefer, and tell the agent which one you picked.

---

You are on my Proxmox homelab CT. Turn my news + watch-recommendations app into a **dynamic, self-hosted web app** served by this CT. Today it's static files on GitHub Pages, with feedback sent through GitHub issue tabs. My recommender, **Grok Bot**, runs in the cloud and **cannot reach my LAN**. It must keep pushing data updates in, and it must keep reading my feedback, without any inbound exposure by default.

Work idempotently, so re-running any step is safe. Show command output, stop and report on failure, and don't guess. Ask me only for the things listed in §13. Never print, log, or commit a secret.

## 0. Read first (source of truth for data and UI)

Clone or pull `https://github.com/ahvren/shield-recs` (branch `main`) and read:

- `README.md`: file ownership, the `news.json` / `recs.json` keys, the feedback line format, and how the recommender processes feedback.
- `news.json`, `recs.json`, `news_prefs.json`: real samples of the schemas. Derive validators from them; don't invent fields.
- `m/index.html`, `m/sw.js`, `m/manifest.webmanifest`: the current phone/tablet/desktop PWA. This is the feature reference.
- `index.html`: the TV page (Fully Kiosk on the Shield, D-pad nav). `SHIELD.md` covers Shield setup.
- `CURSOR_PROMPT.md` (original static deploy, `deploy.sh`, port **8088**) and `CURSOR_NEWS_PROMPT.md`. The latter is the TV News view spec plus the **GitHub Contents API push algorithm** for feedback. Reuse that algorithm as-is.

## 1. Architecture (keep this shape)

```
 Grok Bot (cloud) ──git push──▶ GitHub ahvren/shield-recs (main)  ◀──pull every 5 min── CT app (LAN)
   writes: news.json, recs.json, news_prefs.json, posters/,      ──append feedback──▶   SQLite + API + UI
           feedback/*processed.json                                 (Contents API)        ▲
   reads:  feedback/news_feedback.jsonl, feedback/feedback.jsonl                          │ HTTPS
                                                                          Shield (Fully Kiosk), phone PWA,
                                                                          tablet, PC  — LAN or Tailscale
```

- **GitHub is the data bus.** It's outbound-only from the CT, so no ports are opened.
- **The CT is the app.** It serves the UIs, a JSON API and SQLite state, and is reachable on the LAN and, optionally, over Tailscale.
- **Optional real-time ingest** (§9) is off by default.

## 2. Discovery: reconcile with what exists (do this before changing anything)

1. Inventory what currently runs:
   - `ss -ltnp`, `systemctl list-units --type=service,timer | grep -i shield`, `docker ps -a` (if present), `ls -la /opt/shield-recs /etc/shield-recs /var/lib/shield-recs`
   - nginx/Caddy configs, and crontab entries
2. Identify these and write them down:
   - what serves **:8088** (nginx or docker from `deploy.sh`, or an app Cursor built earlier)
   - the existing pull timer (`shield-recs-pull.timer`, `/usr/local/bin/shield-recs-update`)
   - any existing feedback pusher and its queue files (recs `feedback/feedback.jsonl`, news `feedback/news_feedback.jsonl`)
   - the `RECOMMENDATIONS_URL` / raw-URL settings
   - Projectivy / Fully Kiosk start URLs mentioned in local docs
3. Check that `/etc/shield-recs/github_token` exists, has mode 600, is owned by root (or the service user), and is a fine-grained PAT. Test it read-only: `curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat /etc/shield-recs/github_token)" https://api.github.com/repos/ahvren/shield-recs` should print `200`. Don't echo the token.
4. **Plan:** the new service runs **alongside** the old one on a new port (suggest **8090**) until §12 cutover. Reuse the existing queue and pusher code if it's sound; don't create a second pusher that writes the same file.

## 3. Data contracts

### Inbound (Grok Bot → repo → CT). The CT reads these and never writes them.

| Path | Contract (see README + sample) | Notes |
|---|---|---|
| `news.json` | `version`==1, `generated` ISO-UTC, `window_hours`, `topics[]{id,label,count}`, `items[]{id(16 hex), topic, title, source, url, published, summary, score, image?}` | `summary` is now ~500–700 chars of plain text. `id` = sha256(url)[:16] and is stable across builds. Expect 100–150 items. |
| `recs.json` | `rows[]{label, items[]}` (Movies, Shows), `anime{label, items[]}`, `services{name:{color,package}}`, `generated`, `region`, … | Item fields: title, year, type (movie\|show), services[], links{}, poster (relative path), why, synopsis, genres[], imdb, tmdb, justwatch. |
| `posters/*.jpg` | Referenced by `recs.json` `poster` | Serve with long cache. |
| `news_prefs.json` | topic_weights, muted_topics, muted_sources, boosted_*, excluded_terms, window_hours, target_items | Recommender-owned. The CT may display it, but must **never write** it. |
| `feedback/news_processed.json`, `feedback/processed.json` | `{"processed_ids":[...], ...}` | Recommender-owned. Never write these. |

**Validation:** parse the JSON, check the required keys and types above, and check that the item count is greater than 0 (news ≥ 20). Reject a file that is more than 5 MB. Ignore unknown fields. On failure, **keep the last good copy**, log the reason, and expose it in `/api/status`. Import atomically: either a single SQLite transaction (`BEGIN IMMEDIATE` … replace snapshot … `COMMIT`), or write the files to a temp path and `rename`.

### Outbound (CT → repo). These are the only paths the CT may write, append-only.

`feedback/news_feedback.jsonl`: one compact JSON object per line, `\n`-terminated. The shape is exactly as today:

```json
{"id":"<uuid4>","ts":"2026-10-25T18:17:16Z","item_id":"<news id>","topic":"homelab","source":"r/selfhosted","title":"...","action":"up"}
```

- `action` is one of `up | down | more_like_this | hide_topic | hide_source | unhide_topic | unhide_source | undo`.
- `unhide_*` and `undo` are new. `undo` carries `"undoes":"<event id>"`.
- Optional additive fields: `"device":"tv|phone|tablet|desktop"` and `"test":true`. Every event generated by tests, curl checks or development **must** have `"test": true`.

`feedback/feedback.jsonl` (recs / Watch tab): the same shape as the existing lines, plus the optional `device` and `test` fields:

```json
{"id":"<uuid4>","ts":"...Z","tmdb":95557,"title":"Invincible","type":"show","action":"rate","rating":9.0}
```

- `action` is one of `rate` (`rating` 1–10, step 0.5) | `decline` | `undo` (with `undoes`).

**Rules:**

- Never rewrite or remove existing lines.
- Ids are UUIDv4.
- `ts` is second-precision UTC with a `Z` suffix.
- Commit only these two paths, using a hard-coded allowlist.
- Use the push algorithm from `CURSOR_NEWS_PROMPT.md` §3: GET sha, append, PUT, retry 409/422, back off 5xx/429, pause on 401/403, one commit per flush, idempotent by id.
- **Undo window:** hold each event for 15 s before it's eligible to sync. An undo inside that window deletes the unsynced event, and nothing is pushed. After it has synced, append an `undo` event instead.

**Legacy GitHub issues:** older phone builds open issues labelled `news-feedback`. Grok Bot keeps reading and closing those during the transition, so the CT must not touch issues.

## 4. Sync-in (pull)

A systemd timer runs every **5 min** (`OnBootSec=1min`, `OnUnitActiveSec=5min`, `RandomizedDelaySec=30`, `Persistent=true`), plus `POST /api/admin/pull` for an on-demand pull.

**Preferred method:** `git fetch` over HTTPS into a managed checkout, then `reset --hard origin/main` (the same approach as the current updater). Authenticate with a `GIT_ASKPASS` helper that cats `/etc/shield-recs/github_token` (username `x-access-token`). **Never** put the token in the remote URL, `.git/config`, unit files or logs. Only re-import when `HEAD` changes.

**Alternative** if no git: use the Contents API with `If-None-Match: <etag>` per file. A 304 means skip.

This must work for both a **public and a private** repo; test both by checking `git ls-remote` with and without the askpass. After each pull, validate and import (§3), copy `posters/` to the static dir, and notify open clients through SSE or a `generated` timestamp they poll every 5 min.

## 5. Feedback API and server-side state

- **SQLite** at `/var/lib/shield-recs/app.db` (WAL mode). Suggested tables:
  - `events` (id, kind news|recs, payload JSON, created, eligible_at, synced_at, test)
  - `state` (hidden items, topics and sources; marks; topic/source boosts; ratings; declines; for a single profile `chris`)
  - `meta` (pull/push status)
- **Feedback is instant:** a UI tap POSTs to the API, updates `state`, and returns the new state. Hides, marks and boosts are **server-side and shared across all devices**. The phone keeps a small localStorage mirror and an offline outbox that flushes on reconnect, and replaces the old per-device-only state.
- **Ranking for "For you":** `score + topic_boost + source_boost`, with server hides removed, as in `m/index.html` `visible()`. Hidden stories older than 14 days are pruned.
- Import any existing local CT queue and hide state into SQLite once. Mark imported Cursor test events as `test:true` if they match the earlier test events listed in `feedback/processed.json` `ignored_test_events`.

### API (JSON; suggested)

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/news?topic=&offset=&limit=` | Ranked, hide-filtered items, plus topics with counts and `generated` |
| GET | `/api/recs` | `recs.json` plus per-title rating/declined state |
| GET | `/api/state` | Hides, marks, boosts and the queue count (for the settings sheet) |
| POST | `/api/news/feedback` | `{item_id, action, device?}`. The server fills topic, source and title from the snapshot. Returns `{ok, event_id, state}`. |
| POST | `/api/recs/feedback` | `{tmdb, action: rate\|decline, rating?}` |
| POST | `/api/undo` | `{event_id}` |
| POST | `/api/state/unhide` | `{kind: item\|topic\|source, key}`. Emits `unhide_*` events for topic and source. |
| POST | `/api/state/reset` | Resets local tweaks. This is confirmed in the UI and **emits no events**. |
| GET | `/api/status` | Last pull (sha, time, validation errors), last push (time, result), pending events, version |
| GET | `/healthz` | `200 ok` |
| GET | `/img?u=` | Optional image proxy and resizer, per `CURSOR_NEWS_PROMPT.md`, with an allowlist of http(s), a size cap and a cache. |

## 6. Front-ends (port; feature parity is required)

**Phone / tablet / desktop: port `m/` and keep every current feature and look:**

- dark theme
- News and Watch tabs, with topic chips
- Discover-style cards with image, meta, title and summary clamp, plus the **More/Less** toggle (shown only when text overflows)
- five feedback buttons as **frosted glass circles** (`rgba(255,255,255,.16)`): solid white thumbs up/down, line plus, eye-off and ban icons, **no emoji anywhere**
- 5 s toast with **Undo**
- settings sheet with hidden lists and unhide
- incremental rendering (20/24/36 per batch) with IntersectionObserver
- pull-to-refresh
- responsive layouts:
  - phone portrait is **pixel-identical** to the current build below 600 px
  - 2–3 column grid from 600 px and in landscape
  - desktop at 1100 px and up: max 1440 px, sticky left topic rail with counts, 4 columns, hover and focus rings, settings as a right panel
  - short landscape keeps the action row visible

Changes from the static version:

- The data source becomes the API. Relative `../news.json` and `../recs.json` become `/api/news` and `/api/recs`.
- Feedback becomes POSTs, so **no GitHub tabs**. **Batch mode becomes optional:** keep the toggle, but default it OFF everywhere, because feedback is instant. Keep the offline outbox.
- Add Watch-tab feedback (rate 1–10 / decline) using the recs contract.

**PWA requirements:**

- The PWA must stay installable: valid manifest with `orientation:any`, a service worker (bump `VER`), HTTPS (§10), and `start_url`/`scope` matching the new path (suggest serving the phone app at `/m/` and the TV at `/`).
- The service worker caches the app shell. API GETs are network-first with a cache fallback ("Offline" banner). POSTs go to an outbox.

**TV (Shield, Fully Kiosk):**

- Port `index.html` with glass tiles, D-pad navigation, Movies/Shows/Anime rows, a details card and `intent:` "Open in app" links (the service map comes from `recs.json`).
- Add rate/decline on the TV.
- Add the **News view** per `CURSOR_NEWS_PROMPT.md`, which may already be built; reuse it. Its feedback goes to the same API.
- Large focus rings, and no hover-only UI.

**Everywhere:** `<meta name="robots" content="noindex,nofollow,noarchive">` plus an `X-Robots-Tag: noindex` header.

## 7. Stack (your choice; keep it light)

My suggestion is **Python 3 + FastAPI/uvicorn + SQLite** (or Node + Fastify + better-sqlite3), as a single systemd service running as an unprivileged `shield-recs` user, with static files served by the app or by **Caddy** in front. No frontend framework is needed; vanilla JS is fine and preferred, since the current pages are vanilla. Units:

- `shield-recs-app.service`
- `shield-recs-pull.timer` (reuse or replace the existing one; keep exactly one)
- the push flusher, inside the app or as `shield-recs-push.timer`

Use `Restart=on-failure` and hardening (`NoNewPrivileges`, `ProtectSystem=strict`, `ReadWritePaths=/var/lib/shield-recs`). Back up `app.db` nightly to `/var/lib/shield-recs/backups/` and keep 7 copies.

## 8. Security

- **No secrets in the repo or in units.** Token files are mode `600`, owned by the service user: `/etc/shield-recs/github_token`, plus the optional `/etc/shield-recs/ingest_token`.
- **CORS:** allow only the app's own origins (LAN host:port, the Tailscale hostname). No `*`.
- **Rate limits:** feedback at 30/min per client and 500/day total, returning 429. Reject bodies over 8 KB. Validate `action` values and ids against the current snapshot.
- Admin endpoints (`/api/admin/*`, `/api/state/reset`) are LAN/Tailscale-only. An optional basic token is fine.
- Add security headers: CSP (self plus the image hosts, or the proxy only), `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`.
- Logs never contain tokens or Authorization headers.
- The PAT I once pasted in chat must be treated as exposed. Confirm with me that it was regenerated (§13).

## 9. Optional real-time ingest (OFF by default)

`POST /api/ingest` accepts `{"file":"news.json|recs.json|news_prefs.json","content":{...}}`. Expose it **only** through a Cloudflare Tunnel (`cloudflared`, a dedicated hostname, path-restricted to `/api/ingest`) or Tailscale Funnel, behind `Authorization: Bearer <token>`. The token is in `/etc/shield-recs/ingest_token`; compare it in constant time. It applies the same validation and atomic import as §4 and records the source as `ingest`. GitHub stays the source of truth: the next git pull wins if its `generated` value is newer.

**Tradeoffs:** updates arrive within seconds instead of within 5 min, but this adds a public endpoint, a second secret to rotate, and another moving part. Since Grok Bot updates daily and weekly, 5-minute pulls are enough. Leave it disabled (`INGEST_ENABLED=false`) unless I ask, and document how to enable it.

## 10. Remote access and HTTPS

- **Recommended: Tailscale on the CT.** For an unprivileged LXC, add `/dev/net/tun` to the CT config, or use userspace networking. Run `tailscale serve --bg https / http://127.0.0.1:8090`. This gives a valid `https://<ct>.<tailnet>.ts.net` cert, so the PWA installs and the service worker works. Then install Tailscale on my phone.
- **Alternative: Cloudflare Tunnel plus Cloudflare Access** (email OTP for my address only) for the UI hostname. Keep ingest on a separate path or hostname.
- **LAN-only otherwise:** `http://<ct-ip>:8090/` works for the Shield. The phone PWA needs HTTPS to install, so use the Tailscale URL even at home.
- Don't open router ports.

## 11. Grok Bot side (don't implement; note in the README)

Grok Bot keeps pushing data files and reading both feedback jsonl files. It will ignore `test:true` events, honor `undo` and `unhide_*`, and keep closing legacy issues. If the repo goes private, nothing changes for it (it pushes as `ahvren`).

## 12. Migration with rollback

1. **Build alongside:** the new service on :8090; the old :8088 static site and Pages stay untouched. Run acceptance (§14) against :8090 with `test:true` events only.
2. **Switch clients:**
   - Fully Kiosk Start URL → `http://<ct-ip>:8090/` (or the Tailscale URL), plus the Projectivy tile.
   - Phone: install the PWA from the Tailscale HTTPS URL and remove the old Pages app.
   - PC: bookmark.
3. **Soak** for 3–7 days. Watch `/api/status` for pulls every 5 min and pushes after real taps, and confirm Grok Bot's daily digest reflects the feedback.
4. **Decommission:**
   - Stop the old :8088 server (keep the config for rollback).
   - Disable GitHub Pages (repo Settings → Pages → None).
   - Then make the repo **private** (Settings → General → Danger zone).
   - Re-check that the pull still works with the PAT.
   - Optionally move the app to :8088, or put Caddy on 443.
5. **Rollback** at any step:
   - Point Fully Kiosk and the phone back to the old URL (Pages or :8088).
   - Re-enable Pages (the repo must be public on a free plan).
   - `systemctl disable --now shield-recs-app`.
   - Data is never lost, because GitHub holds all inputs and all synced feedback, and `app.db` backups hold local state.

## 13. What I (Chris) must do; ask me only for these

- [ ] Regenerate the fine-grained PAT if not done yet (the old one was pasted in chat). Settings: Only `ahvren/shield-recs`, Contents read/write. Put it at `/etc/shield-recs/github_token` (mode 600) myself.
- [ ] Choose remote access: Tailscale (install it on the CT and phone, approve the device), or a Cloudflare Tunnel plus Access.
- [ ] Update the Fully Kiosk Start URL and Projectivy tile, and install the phone PWA from the new HTTPS URL.
- [ ] After the soak: disable Pages, make the repo private.
- [ ] Optional: enable ingest and give Grok Bot the ingest URL. I'll pass the token to it out of band, never in chat.

## 14. Acceptance checklist (show evidence for each)

- [ ] `systemctl status shield-recs-app` is active. `/healthz` returns 200. There is exactly one pull timer and exactly one pusher.
- [ ] A pull imports the current `news.json` (149±) and `recs.json` (Movies, Shows and Anime with 12 each). `/api/status` shows the sha. A corrupted test file is rejected and the last good copy is kept.
- [ ] The pull works with the repo private, simulated by using the askpass-only path. The token doesn't appear in `ps`, `.git/config`, unit files or the journal.
- [ ] Tap thumbs-up on the phone with `test` mode on. Within 15 s plus one flush interval, one new line with `"test":true` appears in `feedback/news_feedback.jsonl` on GitHub, and the commit touches only that path. Undo within 15 s produces no line.
- [ ] Hide a source on the phone, then reload on the desktop and on the TV: it's hidden everywhere. Unhiding it in settings emits `unhide_source`.
- [ ] Watch-tab rate and decline go to `feedback/feedback.jsonl` with the existing shape.
- [ ] Offline: kill the network, tap; the outbox holds the event. Restore the network and it syncs exactly once (no duplicate ids).
- [ ] UI parity: screenshots at 412×900, 900×412, 1180×820 and 1600×1000 match the current `m/` build (phone portrait pixel-identical), with More/Less working. The TV page passes a D-pad walkthrough, and Open-in-app works for Crunchyroll.
- [ ] The PWA installs from the HTTPS URL (Chrome "Install app") and the service worker is active (DevTools → Application).
- [ ] Security: CORS rejects a foreign Origin, the 31st feedback POST in a minute gets a 429, `noindex` is present, and `/.git` and `*.md` return 404.
- [ ] Ingest is disabled, and `/api/ingest` returns 404/403 unless enabled.
- [ ] A local `README` documents paths, units, ports, the status endpoint, how to flush or inspect the outbox, rollback, and enabling ingest.

**Report back:** URLs (LAN and Tailscale), the files and units created or changed, the acceptance evidence, and anything that still needs me.
