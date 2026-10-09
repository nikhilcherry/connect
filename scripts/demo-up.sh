#!/usr/bin/env bash
# Everything the phones need from this laptop, in one command. Run it after a
# reboot, or whenever the app says it is offline. It starts only what is not
# already running, so it is safe to run again.
#
#   scripts/demo-up.sh            start the stack, the functions and the scan page, then check each
#   scripts/demo-up.sh --watch    the same, then stay up and repair whatever drops (the tunnel does)
#   scripts/demo-up.sh --publish  also put the scan page on a public address through the tunnel
#
# The phones' builds talk to $API; their QR tags point at $SCAN (see README,
# "Demo backend on a laptop"). Both come down with `hoist down connect-api connect`.
set -uo pipefail
cd "$(dirname "$0")/.."
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
API="${CONNECT_API_URL:-https://connect-api.premortem.tech}"
SCAN="${CONNECT_SCAN_URL:-https://connect.premortem.tech}"
PAGE_PORT=8093
LOGS="${XDG_STATE_HOME:-$HOME/.local/state}/connect-demo"
mkdir -p "$LOGS"

code() { curl -s -m "${2:-6}" -o /dev/null -w '%{http_code}' "${@:3}" "$1" 2>/dev/null || true; }
scan_code() { code "$1/functions/v1/scan" 8 -X POST -H 'content-type: application/json' -d '{"action":"lookup","code":"ZZZZZZZZ"}'; }
say() { printf '%-12s %s\n' "$1" "$2"; }
wait_for() { for _ in $(seq 1 "$2"); do [ "$($1)" = "$3" ] && return 0; sleep 1; done; return 1; }

stack_up() { [ "$(code http://127.0.0.1:54321/rest/v1/)" = 200 ]; }
functions_up() { [ "$(scan_code http://127.0.0.1:54321)" = 404 ]; }   # an unknown tag is a 404 from the function itself
page_up() { [ "$(code http://127.0.0.1:$PAGE_PORT/)" = 200 ]; }

ensure() {
  if ! stack_up; then
    say stack "starting"
    supabase start >"$LOGS/stack.log" 2>&1 || say stack "failed, see $LOGS/stack.log"
  fi
  if ! functions_up; then
    say functions "starting"
    setsid nohup supabase functions serve --no-verify-jwt --env-file supabase/functions/.env.local >"$LOGS/functions.log" 2>&1 </dev/null &
    wait_for "scan_code http://127.0.0.1:54321" 40 404 || say functions "not answering, see $LOGS/functions.log"
  fi
  if ! page_up; then
    say "scan page" "starting on :$PAGE_PORT"
    CONNECT_API_URL="$API" setsid nohup python3 web/serve.py "$PAGE_PORT" >"$LOGS/page.log" 2>&1 </dev/null &
    wait_for "code http://127.0.0.1:$PAGE_PORT/" 10 200 || say "scan page" "not answering, see $LOGS/page.log"
  fi
  # Cloudflare answers 530 when the tunnel has no live connection. That happens without
  # cloudflared noticing whenever the laptop's route changes (a phone starts USB tethering).
  if [ "$(code "$API/rest/v1/" 10)" = 530 ]; then
    say tunnel "down, restarting cloudflared"
    sudo -n /usr/bin/systemctl restart cloudflared || say tunnel "could not restart: run  sudo systemctl restart cloudflared"
    wait_for "code $API/rest/v1/ 10" 20 200 || true
  fi
}

report() {
  say stack "$(stack_up && echo ok || echo DOWN)"
  say functions "$(functions_up && echo ok || echo DOWN)"
  say "scan page" "$(page_up && echo "ok on :$PAGE_PORT" || echo DOWN)"
  say "api (public)" "$(code "$API/rest/v1/" 10) from $API   (scan function: $(scan_code "$API"), 404 is right)"
  say "page (public)" "$(code "$SCAN/" 10) from $SCAN   (anything but 200: not published, run with --publish)"
}

ensure
if [[ " $* " == *" --publish "* ]]; then
  host="${SCAN#https://}"
  if hoist ls 2>/dev/null | grep -q "$host"; then say publish "$host already published"
  else hoist adopt connect --port "$PAGE_PORT" --hostname "$host" --no-qr || say publish "failed"; fi
fi
report
if [[ " $* " == *" --watch "* ]]; then
  say watch "checking every 20 s; Ctrl-C to stop"
  while sleep 20; do ensure; done
fi
