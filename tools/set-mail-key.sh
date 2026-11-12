#!/bin/bash
# Turns on Work Clock emails: copies the CRM's Resend key into Supabase Vault.
# Reads keys from the CRM's .env.local and never prints them.
set -euo pipefail
ENV="${1:-$HOME/Documents/team-angeleski-crm/.env.local}"
set -a; . "$ENV" >/dev/null 2>&1; set +a
curl -fsS -X POST "${NEXT_PUBLIC_SUPABASE_URL%/}/rest/v1/rpc/focus_admin_set_mail_key" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c 'import json,os;print(json.dumps({"p_key":os.environ["RESEND_API_KEY"]}))')"
echo
echo "Email alerts are on."
