#!/bin/bash
# Turns on Work Clock emails: copies the CRM's Resend key into Supabase Vault.
# Reads only the three values it needs from the CRM's .env.local and never prints them.
set -euo pipefail
ENV="${1:-$HOME/Documents/team-angeleski-crm/.env.local}"
[[ -f "$ENV" ]] || { echo "Can't find $ENV"; exit 1; }

python3 - "$ENV" <<'PY'
import json, sys, urllib.request, urllib.error

env = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")

missing = [k for k in ("NEXT_PUBLIC_SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "RESEND_API_KEY") if not env.get(k)]
if missing:
    sys.exit("Missing in .env.local: " + ", ".join(missing))

svc = env["SUPABASE_SERVICE_ROLE_KEY"]
req = urllib.request.Request(
    env["NEXT_PUBLIC_SUPABASE_URL"].rstrip("/") + "/rest/v1/rpc/focus_admin_set_mail_key",
    data=json.dumps({"p_key": env["RESEND_API_KEY"]}).encode(), method="POST",
    headers={"apikey": svc, "Authorization": "Bearer " + svc, "Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=20).read()
    print("✅ Email alerts are on.")
except urllib.error.HTTPError as e:
    sys.exit(f"❌ Supabase said {e.code}: {e.read().decode()[:300]}")
PY
