#!/usr/bin/env bash
set -euo pipefail
cd /srv/margin/deploy

# Build before touching the running service. Serialize manual and CI deployments.
exec 9>/srv/margin/deploy/.deploy.lock
flock -w 900 9
docker compose config --quiet
docker compose build api

# SQLite online backup includes committed WAL data while the service is running.
if docker compose ps --status running --services | grep -qx api; then
  docker compose exec -T api sqlite3 /data/library.sqlite \
    '.backup /data/library-pre-deploy.sqlite'
fi

docker compose up -d --wait --wait-timeout 120
# Caddy has admin disabled: restart it to load any updated proxy configuration.
docker compose restart proxy
curl --fail --silent --show-error --retry 12 --retry-delay 5 --retry-all-errors \
  --resolve books.0xff.shop:8443:127.0.0.1 \
  https://books.0xff.shop:8443/healthz
docker compose ps
