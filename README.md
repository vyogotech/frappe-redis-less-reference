# frappe-redis-less-reference

Reference Docker assets used to validate Redis-less Frappe startup against the custom `vyogo/erpnext:sne-version-16` image.

This repo contains the exact supporting artifacts used for end-to-end validation of the Frappe change proposed in `frappe/frappe` issue `#39478`:
- a custom `Dockerfile`
- a Redis-less S2I run script
- a `docker-compose.yml`
- the patched Frappe runtime files injected into the image

## What this is for

This is a companion reference repo for the upstream Frappe PR. It demonstrates the container setup used to verify that Frappe can run without Redis in developer onboarding scenarios.

It is not intended to replace the upstream Frappe source changes. Those belong in the main PR.

## Files included

- `Dockerfile` builds on `docker.io/vyogo/erpnext:sne-version-16`
- `run-no-redis.sh` replaces the S2I run entrypoint and skips Redis startup
- `patched/frappe/utils/redis_wrapper.py` enables the in-memory cache fallback
- `patched/frappe/utils/background_jobs.py` makes Redis-backed enqueue paths safe in Redis-less mode
- `patched/frappe/utils/scheduler.py` prevents the scheduler from dequeuing against the memory backend
- `docker-compose.yml` runs the image locally for validation

## Build

```bash
docker build -t vyogo/erpnext:redis-less-test .
```

## Run

```bash
docker compose up -d
```

Then verify:

```bash
curl http://localhost:8000/api/method/ping
```

Optional automatic setup:

```bash
AUTO_SETUP=true docker compose up -d --build
```

## Validation notes

This setup was used to verify:
- Frappe starts without Redis
- the in-memory cache fallback is activated
- setup can complete without Redis
- `/desk` loads successfully after setup
- `system_health_report` no longer crashes due to missing `execute_command`

## Licensing

The patched Frappe source files in `patched/` are derived from the Frappe project and are included here for reference under the same project license. See `LICENSE`.
