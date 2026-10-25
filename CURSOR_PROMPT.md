# Cursor agent prompt: serve shield-recs on the homelab VM

Paste everything below the line into a Cursor agent running **on the Ubuntu homelab VM** (shell access, sudo available).
First, replace `https://github.com/ahvren/shield-recs.git` with the real clone URL, e.g. `https://github.com/ahvren/shield-recs.git`.

---

You are on my Ubuntu homelab VM. Set up a self-updating static site for my NVIDIA Shield recommendations page. Everything must be **idempotent**, so re-running any step is safe and never creates duplicates. Don't ask me questions unless something blocks you. Show me each command's output, and stop and report if a step fails. Don't guess.

**Inputs**
- REPO_URL = `https://github.com/ahvren/shield-recs.git`
- BRANCH = `main`
- DIR = `/opt/shield-recs`
- PORT = `8088`
- Pull interval = every 30 minutes

The repo contains `index.html`, `recs.json`, `posters/*.jpg`, `deploy.sh`, and docs. `index.html` fetches `recs.json` at runtime, so serving the files is all that's needed. No build step.

**Steps**

1. **Preflight.** Run `lsb_release -a`, `id`, `sudo -n true`. Check whether port 8088 is already in use: `sudo ss -ltnp 'sport = :8088'`. If something other than a previous shield-recs nginx or container holds it, stop and tell me what it is. Check whether Docker works: `docker info >/dev/null 2>&1 && echo docker-ok`.
2. **Access check.** Run `git ls-remote "$REPO_URL" HEAD`. If it fails because the repo is private, stop and tell me. Give me two options: (a) a read-only deploy key, where you generate `ssh-keygen -t ed25519 -f /root/.ssh/shield-recs -N ""` and show me the public key to add under repo Settings > Deploy keys, then use the `git@github.com:` URL with `GIT_SSH_COMMAND` / an ssh config Host entry; or (b) make the repo public. Never ask for or store a personal access token in plain text.
3. **Content.** `apt-get install -y git ca-certificates curl` (only if missing). If `$DIR/.git` exists, `git -C $DIR remote set-url origin $REPO_URL`; otherwise `git clone --branch $BRANCH --single-branch $REPO_URL $DIR`. If `$DIR` exists but isn't a git checkout, stop and ask me.
4. **Updater.** Create `/usr/local/bin/shield-recs-update` (mode 755). It should `cd $DIR` and run `git fetch --prune origin +refs/heads/$BRANCH:refs/remotes/origin/$BRANCH`. If HEAD differs from `origin/$BRANCH`, it should run `git reset --hard origin/$BRANCH && git clean -fdq`. This is a `git pull` that also survives force-pushes; the checkout is never edited by hand. It ends by printing `git log -1 --oneline`. Run it once.
5. **Web server.** Use exactly one of these:
   - **Docker present:** write `/etc/shield-recs/nginx-docker.conf`, then (re)create the container only if it's missing, stopped, or its config changed (compare a label such as `shield-recs.sig`): `docker run -d --name shield-recs --restart unless-stopped -p 8088:80 -v /opt/shield-recs:/usr/share/nginx/html:ro -v /etc/shield-recs/nginx-docker.conf:/etc/nginx/conf.d/default.conf:ro nginx:alpine`.
   - **No Docker:** `apt-get install -y nginx`, write `/etc/nginx/sites-available/shield-recs` (listen 8088 and [::]:8088, root /opt/shield-recs), symlink it into `sites-enabled` with `ln -sfn`, run `nginx -t`, then `systemctl enable --now nginx && systemctl reload nginx`. Don't touch the default site or any other site.
   - The server block in both cases must include: `index index.html;`, deny `/.git` (404), deny `*.sh` and `*.md` (404), `Cache-Control: no-cache` on `/recs.json` and `/index.html`, and `Cache-Control: public, max-age=86400` on `/posters/`.
6. **Timer.** Create `/etc/systemd/system/shield-recs-pull.service` (Type=oneshot, After/Wants=network-online.target, ExecStart=/usr/local/bin/shield-recs-update). Create `/etc/systemd/system/shield-recs-pull.timer` (OnBootSec=2min, OnUnitActiveSec=30min, RandomizedDelaySec=60, Persistent=true, WantedBy=timers.target). Run `systemctl daemon-reload && systemctl enable --now shield-recs-pull.timer`. Use systemd rather than cron. If an old cron line for shield-recs exists, remove it so there's only one scheduler.
7. **Firewall.** Only if `ufw status` shows active, run `ufw allow 8088/tcp`. Don't enable ufw if it's off.
8. **Verify and report.** Run all of these:
   - `curl -sI http://127.0.0.1:8088/` (expect 200)
   - `curl -s http://127.0.0.1:8088/recs.json | head -c 300`
   - `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8088/.git/config` (expect 404)
   - `systemctl list-timers shield-recs-pull.timer`
   - `sudo systemctl start shield-recs-pull.service && journalctl -u shield-recs-pull.service -n 5 --no-pager`

   Finish with the LAN URL from `hostname -I`, formatted as `http://<ip>:8088/`, and a list of every file you created or changed.
9. **Idempotency proof.** Run steps 3–7 a second time and show that nothing was duplicated: one container or one nginx site, and one timer.

Shortcut: the repo ships `deploy.sh`, which implements all of the above. You may run `sudo REPO_URL=https://github.com/ahvren/shield-recs.git bash /opt/shield-recs/deploy.sh` after cloning, but read it first and still do steps 1, 2, 8 and 9 yourself.

**Do not:** change any other nginx sites or containers, open ports other than 8088, install anything beyond git, curl, ca-certificates, and nginx (or pull nginx:alpine), or store credentials in the repo or in any unit file.
