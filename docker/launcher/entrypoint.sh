#!/usr/bin/env bash
# Runs with the repo mounted at the SAME absolute path as on the host
# ($PROJECT_DIR): the Supabase CLI hands paths to sibling containers, and the
# host's Docker daemon only understands host paths.
set -euo pipefail
cd "${PROJECT_DIR:?PROJECT_DIR must be the repo path on the host}"
[ -f supabase/functions/.env.local ] || echo "SCAN_IP_HOP=1" > supabase/functions/.env.local
# Show every alert in the demo n8n (see docker-compose.yml); remove the line to switch it off.
if [ -n "${N8N_ALERT_WEBHOOK:-}" ] && ! grep -q '^N8N_ALERT_WEBHOOK=' supabase/functions/.env.local; then
  echo "N8N_ALERT_WEBHOOK=\"${N8N_ALERT_WEBHOOK}\"" >> supabase/functions/.env.local
fi

echo "[backend] supabase start (first run pulls ~2 GB of images)"
supabase start || { echo "[backend] supabase start failed"; exit 1; }

echo "[backend] serving edge functions: scan, notify, rc-lookup, vehicle-vision"
exec supabase functions serve --no-verify-jwt --env-file supabase/functions/.env.local
