#!/usr/bin/env bash
# shield-recs deploy: clone (or update) the recs repo, serve it on :8088, and pull every 30 min.
# Idempotent: safe to re-run any time. Ubuntu 22.04/24.04.
#
# Usage (on the homelab VM):
#   sudo REPO_URL=https://github.com/ahvren/shield-recs.git bash deploy.sh
# Optional env: BRANCH=main PORT=8088 DIR=/opt/shield-recs MODE=auto|docker|nginx INTERVAL=30min
# No REPO_URL? Run it from inside an extracted shield-recs folder and it serves a static copy (no auto-pull).
set -euo pipefail

REPO_URL="${REPO_URL:-${1:-}}"
BRANCH="${BRANCH:-main}"
PORT="${PORT:-8088}"
DIR="${DIR:-/opt/shield-recs}"
MODE="${MODE:-auto}"
INTERVAL="${INTERVAL:-30min}"
NAME="shield-recs"
CONF_DIR="/etc/${NAME}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log(){ printf '\033[1;36m[%s]\033[0m %s\n' "$NAME" "$*"; }
die(){ printf '\033[1;31m[%s] %s\033[0m\n' "$NAME" "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Run with sudo."
command -v apt-get >/dev/null || die "This script expects Ubuntu/Debian (apt-get)."

apt_install(){ # install only what is missing
  local missing=(); for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ ${#missing[@]} -gt 0 ]; then log "apt install ${missing[*]}"; DEBIAN_FRONTEND=noninteractive apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"; fi
}
apt_install ca-certificates curl

# ---------- 1. content ----------
if [ -n "$REPO_URL" ]; then
  apt_install git
  if [ -d "$DIR/.git" ]; then
    log "Repo exists at $DIR; updating remote and pulling"
    git -C "$DIR" remote set-url origin "$REPO_URL"
  else
    [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ] && die "$DIR exists and is not a git checkout. Move it aside or set DIR=."
    log "Cloning $REPO_URL ($BRANCH) into $DIR"
    git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$DIR"
  fi
  # updater used by both this run and the timer
  install -d "$CONF_DIR"
  cat > /usr/local/bin/${NAME}-update <<UPD
#!/usr/bin/env bash
# Pull the latest recs (git pull equivalent). The checkout is managed, never edited by hand, so it
# hard-resets to the remote branch: that also survives force-pushes and history rewrites.
set -euo pipefail
cd "$DIR"
git fetch --quiet --prune origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
if [ "\$(git rev-parse HEAD)" != "\$(git rev-parse "origin/$BRANCH")" ]; then
  git reset --hard --quiet "origin/$BRANCH"
  git clean -fdq
fi
git log -1 --format='[${NAME}] at %h %cI %s'
UPD
  chmod 755 /usr/local/bin/${NAME}-update
  /usr/local/bin/${NAME}-update
else
  [ -f "$SRC_DIR/index.html" ] || die "No REPO_URL and no index.html next to this script."
  log "No REPO_URL: copying $SRC_DIR to $DIR (static, no auto-pull)"
  install -d "$DIR"
  cp -a "$SRC_DIR/." "$DIR/"
fi
chmod -R a+rX "$DIR"

# ---------- 2. web server ----------
NGINX_SERVER_BODY='
    index index.html;
    location ~ /\.(git|github) { deny all; return 404; }
    location = /recs.json { add_header Cache-Control "no-cache"; try_files $uri =404; }
    location = /index.html { add_header Cache-Control "no-cache"; }
    location /posters/ { add_header Cache-Control "public, max-age=86400"; }
    location ~ \.(sh|md)$ { deny all; return 404; }
'
if [ "$MODE" = auto ]; then
  if command -v docker >/dev/null && docker info >/dev/null 2>&1; then MODE=docker; else MODE=nginx; fi
fi
log "Serving with: $MODE on port $PORT"

if [ "$MODE" = docker ]; then
  install -d "$CONF_DIR"
  printf 'server {\n    listen 80;\n    root /usr/share/nginx/html;%s}\n' "$NGINX_SERVER_BODY" > "$CONF_DIR/nginx-docker.conf"
  # if host nginx was set up by an earlier run on the same port, remove that site so ports don't clash
  if [ -L /etc/nginx/sites-enabled/${NAME} ]; then rm -f /etc/nginx/sites-enabled/${NAME}; systemctl reload nginx 2>/dev/null || true; fi
  want="nginx:alpine|$PORT|$DIR|$(sha256sum "$CONF_DIR/nginx-docker.conf" | cut -c1-12)"
  have="$(docker inspect -f '{{ index .Config.Labels "shield-recs.sig" }}' "$NAME" 2>/dev/null || true)"
  if [ "$have" != "$want" ] || [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != true ]; then
    docker pull -q nginx:alpine >/dev/null
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" --restart unless-stopped -p "$PORT:80" \
      --label "shield-recs.sig=$want" \
      -v "$DIR:/usr/share/nginx/html:ro" \
      -v "$CONF_DIR/nginx-docker.conf:/etc/nginx/conf.d/default.conf:ro" \
      nginx:alpine >/dev/null
    log "Container $NAME (re)created"
  else
    log "Container $NAME already up to date"
  fi
else
  apt_install nginx
  # if a container from an earlier docker-mode run holds the port, remove it
  command -v docker >/dev/null && docker rm -f "$NAME" >/dev/null 2>&1 || true
  printf 'server {\n    listen %s;\n    listen [::]:%s;\n    server_name _;\n    root %s;%s}\n' "$PORT" "$PORT" "$DIR" "$NGINX_SERVER_BODY" > /etc/nginx/sites-available/${NAME}
  ln -sfn /etc/nginx/sites-available/${NAME} /etc/nginx/sites-enabled/${NAME}
  nginx -t -q
  systemctl enable --now nginx >/dev/null
  systemctl reload nginx
fi

# ---------- 3. auto-pull timer ----------
if [ -n "$REPO_URL" ]; then
  cat > /etc/systemd/system/${NAME}-pull.service <<UNIT
[Unit]
Description=Pull latest shield-recs from git
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/${NAME}-update
UNIT
  cat > /etc/systemd/system/${NAME}-pull.timer <<UNIT
[Unit]
Description=Pull shield-recs every ${INTERVAL}

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}
RandomizedDelaySec=60
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now ${NAME}-pull.timer >/dev/null
  log "Timer: $(systemctl list-timers ${NAME}-pull.timer --no-legend | awk '{print $1, $2, $3}') (next run)"
fi

# ---------- 4. firewall (only if ufw is already active) ----------
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow "$PORT/tcp" >/dev/null && log "ufw: allowed $PORT/tcp"
fi

# ---------- 5. verify ----------
sleep 1
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/recs.json")"
[ "$code" = 200 ] || die "recs.json returned HTTP $code on port $PORT"
n="$(curl -s "http://127.0.0.1:$PORT/recs.json" | grep -c '"title"' || true)"
ip="$(hostname -I | awk '{print $1}')"
log "OK: $n titles served. Open on the Shield: http://$ip:$PORT/"
