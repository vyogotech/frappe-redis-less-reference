#!/bin/bash -e
#
# Modified S2I run script — Redis-less mode for testing the in-memory cache fallback.
# Skips Redis startup entirely; Frappe falls back to MemoryCacheWrapper automatically.
#

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

error() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2
  exit 1
}

mkdir -p /tmp/pids

# ── MariaDB ──────────────────────────────────────────────────────────────────
log "Starting MariaDB..."
command -v mysqld >/dev/null 2>&1 || error "mysqld is not installed."
mysqld --pid-file=/tmp/pids/mysqld.pid &>/var/log/mysqld.log &
sleep 3
if kill -0 "$(cat /tmp/pids/mysqld.pid 2>/dev/null)" 2>/dev/null; then
  log "MariaDB started (PID $(cat /tmp/pids/mysqld.pid))."
else
  cat /var/log/mysqld.log >&2
  error "MariaDB died immediately. Check /var/log/mysqld.log"
fi

# ── Redis: SKIPPED ────────────────────────────────────────────────────────────
log "Redis startup SKIPPED — running in Redis-less / in-memory cache mode."

# ── Cleanup trap ─────────────────────────────────────────────────────────────
cleanup() {
  log "Stopping services..."
  [ -f /tmp/pids/mysqld.pid ] && (mysqladmin shutdown 2>/dev/null || kill -15 "$(cat /tmp/pids/mysqld.pid)" 2>/dev/null)
  log "All services stopped."
  exit 0
}
trap cleanup SIGINT SIGTERM

# ── Inject use_memory_cache into every site_config.json ──────────────────────
log "Injecting use_memory_cache=true into site configs..."
cd /home/frappe/frappe-bench
for site_cfg in sites/*/site_config.json; do
  if [ -f "$site_cfg" ]; then
    python3 - "$site_cfg" <<'PYEOF'
import sys, json
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
cfg["use_memory_cache"] = True
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print(f"  Patched {path}")
PYEOF
  fi
done

# ── Remove Redis URLs from common_site_config so bench doesn't warn ───────────
log "Removing Redis URLs from common_site_config.json..."
python3 - sites/common_site_config.json <<'PYEOF'
import sys, json
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
for key in ("redis_cache", "redis_queue", "redis_socketio"):
    cfg.pop(key, None)
cfg["in_memory"] = 1
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print(f"  Patched {path}")
PYEOF

# ── Drop Redis-dependent processes from Procfile ─────────────────────────────
# worker:   uses RQ (Redis queue) — crashes on missing Redis
# schedule: bench schedule fires enqueue() every minute; our sync fallback
#            runs those jobs inline inside the scheduler's open DB connection,
#            causing InnoDB lock-wait timeouts for all web requests.
#            For developer onboarding, scheduled jobs are not needed.
log "Patching Procfile — removing worker and schedule; disabling threading..."
sed -i '/^worker:/d' Procfile
sed -i '/^schedule:/d' Procfile
sed -i '/^redis/d' Procfile
# Run web server single-threaded to prevent concurrent requests from racing on
# DB row locks (e.g. SELECT ... FOR UPDATE on System Settings during setup wizard).
# The setup wizard runs a long synchronous transaction; concurrent browser requests
# would time out waiting for the InnoDB row lock.
sed -i 's|bench serve\b|bench serve --nothreading|' Procfile
log "Procfile after patch:"
cat Procfile

# ── Register apps ─────────────────────────────────────────────────────────────
log "Registering apps..."
apps_list=($(find apps/ -maxdepth 1 -mindepth 1 -type d ! -name "frappe"))
apps_in_txt=($(cat sites/apps.txt))
for app in "${apps_list[@]}"; do
  app_name=$(basename "$app")
  env/bin/python3 -m pip install -e "./apps/${app_name}" --quiet || true
  if [[ ! " ${apps_in_txt[@]} " =~ " ${app_name} " ]]; then
    log "Registered app: $app_name"
  fi
done
ls -1 apps/ > sites/apps.txt
log "All apps registered."

# ── Optional assets cache restore ─────────────────────────────────────────────
if [[ "${ENABLE_ASSETS_CACHE:-false}" == "true" ]]; then
  if [ -d "/home/frappe/assets_cache" ] && [ -n "$(ls -A /home/frappe/assets_cache 2>/dev/null)" ]; then
    if [ ! -d "sites/assets/frappe" ]; then
      log "Restoring assets from image cache..."
      mkdir -p sites/assets
      cp -r /home/frappe/assets_cache/. sites/assets/
      log "Assets restored."
    fi
  fi
fi

# ── Allow remote MariaDB connections ─────────────────────────────────────────
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e \
  "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${MYSQL_ROOT_PASSWORD}'); \
   GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>/dev/null || true

# ── Clear cache (will use in-memory backend now) ─────────────────────────────
bench --site all clear-cache || true

# ── Auto-setup wizard (optional) ─────────────────────────────────────────────
# Set AUTO_SETUP=true to run the setup wizard automatically from CLI instead of
# going through the browser UI. Runs in the background after web server is ready.
# Customize via env vars:
#   SETUP_COUNTRY, SETUP_TIMEZONE, SETUP_CURRENCY, SETUP_LANGUAGE
#   SETUP_FULL_NAME, SETUP_EMAIL, SETUP_PASSWORD
#   SETUP_COMPANY_NAME, SETUP_COMPANY_ABBR, SETUP_CHART_OF_ACCOUNTS
if [[ "${AUTO_SETUP:-false}" == "true" ]]; then
  _SITE=$(python3 -c "import json; d=json.load(open('sites/common_site_config.json')); print(d.get('default_site','dev.localhost'))" 2>/dev/null || echo "dev.localhost")
  (
    log "[auto-setup] Waiting for web server on port 8000..."
    for i in $(seq 1 60); do
      if curl -sf --max-time 2 http://localhost:8000/api/method/ping >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done

    # Check if setup is already complete
    _DONE=$(mysql -u "$(python3 -c "import json; print(json.load(open('sites/${_SITE}/site_config.json'))['db_user'])")" \
      -p"$(python3 -c "import json; print(json.load(open('sites/${_SITE}/site_config.json'))['db_password'])")" \
      "$(python3 -c "import json; print(json.load(open('sites/${_SITE}/site_config.json'))['db_name'])")" \
      -sNe "SELECT value FROM tabSingles WHERE doctype='System Settings' AND field='setup_complete';" 2>/dev/null || echo "0")
    if [[ "$_DONE" == "1" ]]; then
      log "[auto-setup] Setup already complete — skipping."
      exit 0
    fi

    log "[auto-setup] Running setup wizard for site: ${_SITE} ..."
    bench --site "${_SITE}" execute \
      frappe.desk.page.setup_wizard.setup_wizard.setup_complete \
      --kwargs "{
        \"args\": {
          \"language\":            \"${SETUP_LANGUAGE:-English}\",
          \"country\":             \"${SETUP_COUNTRY:-Australia}\",
          \"timezone\":            \"${SETUP_TIMEZONE:-Australia/Sydney}\",
          \"currency\":            \"${SETUP_CURRENCY:-AUD}\",
          \"full_name\":           \"${SETUP_FULL_NAME:-Administrator}\",
          \"email\":               \"${SETUP_EMAIL:-admin@example.com}\",
          \"password\":            \"${SETUP_PASSWORD:-admin}\",
          \"company_name\":        \"${SETUP_COMPANY_NAME:-My Company}\",
          \"company_abbr\":        \"${SETUP_COMPANY_ABBR:-MC}\",
          \"chart_of_accounts\":   \"${SETUP_CHART_OF_ACCOUNTS:-Standard}\"
        }
      }" && log "[auto-setup] Setup complete! Open http://localhost:8000/desk" \
           || log "[auto-setup] ERROR: setup wizard failed — check logs above."
  ) &
  log "Auto-setup forked in background (PID $!)."
fi

# ── Start ─────────────────────────────────────────────────────────────────────
log "Starting Frappe/ERPNext (Redis-less mode)..."
bench start

error "bench exited unexpectedly!"
