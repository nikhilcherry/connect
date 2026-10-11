#!/bin/sh
# Loads the two demo workflows and their credentials, publishes them, starts n8n.
set -e
mkdir -p /tmp/seed
JEV_KEY="${JEV_API_KEY:-}"
OR_KEY="${OPENROUTER_API_KEY:-}"
cat > /tmp/seed/creds.json <<JSON
[
 {"id":"x2DZZC4NtTAyBygm","name":"TypeSafe Jev API","type":"httpHeaderAuth",
  "data":{"name":"Authorization","value":"Bearer ${JEV_KEY}","allowedHttpRequestDomains":"domains","allowedDomains":"api.typesafe.ai"}},
 {"id":"Kx1wVLWR92ZVFDIq","name":"OpenRouter (traffic AI)","type":"openRouterApi",
  "data":{"apiKey":"${OR_KEY}","allowedHttpRequestDomains":"domains","allowedDomains":"openrouter.ai"}}
]
JSON
n8n import:credentials --input=/tmp/seed/creds.json
n8n import:workflow --input=/seed/alert-flow.json
n8n import:workflow --input=/seed/whisper-relay.json
# The violation dispatcher emails a demo inbox (DEMO_INBOX); real stations are set in its routing table.
sed "s/DEMO_INBOX_PLACEHOLDER@example.com/${DEMO_INBOX:-you@example.com}/g" /seed/violation-dispatcher.json > /tmp/seed/violation-dispatcher.json
n8n import:workflow --input=/tmp/seed/violation-dispatcher.json
n8n publish:workflow --id=cZxnlGpLKAlDq4cH
n8n publish:workflow --id=sP1Bke2lWm5hjfUZ
n8n publish:workflow --id=va5wUJu6zXoyDByd
rm -rf /tmp/seed
exec n8n start
