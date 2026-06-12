#!/usr/bin/env bash
# Bootstrap the FIRST platform admin.
#
# Self-service registration is disabled platform-wide — accounts are created by
# an admin from the portal (/admin/users). That's a chicken-and-egg for a fresh
# install, so this script creates the first identity directly against the
# Kratos admin API and grants it the admin role in Keto. It then prints a
# one-time recovery link + code: open the link, enter the code, set a password.
# The portal provisions the rest (paired .bot identity, Gitea
# accounts) on first login. Create every subsequent user from the portal UI.
#
# Usage:
#   ./bootstrap-admin.sh --email you@example.com --username you \
#     [--namespace-prefix cv-]
#
# Requires: kubectl (pointed at the cluster), jq. Runs its curl calls inside
# the <prefix>ory namespace because the platform NetworkPolicies only admit
# Kratos/Keto admin traffic from there.

set -euo pipefail

EMAIL=""
USERNAME=""
NSP="cv-"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)            EMAIL="$2"; shift 2 ;;
    --username)         USERNAME="$2"; shift 2 ;;
    --namespace-prefix) NSP="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | head -n -1 | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$EMAIL" && -n "$USERNAME" ]] || { echo "ERROR: --email and --username are required (see --help)" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

NS_ORY="${NSP}ory"

# curl from inside the ory namespace; NetworkPolicies block admin-API callers
# from anywhere else.
kcurl() {
  kubectl run -n "$NS_ORY" "cv-bootstrap-curl-$RANDOM" --rm -i --restart=Never \
    --quiet --image=curlimages/curl:8.10.1 --command -- \
    curl -sS --fail-with-body "$@"
}

echo "==> Creating Kratos identity for $EMAIL"
IDENTITY_JSON=$(kcurl -X POST http://ory-kratos-admin:4434/admin/identities \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg email "$EMAIL" --arg username "$USERNAME" \
        '{schema_id: "person", traits: {email: $email, preferred_username: $username}}')") \
  || { echo "ERROR: identity create failed (already exists?): $IDENTITY_JSON" >&2; exit 1; }
IDENTITY_ID=$(jq -r '.id' <<<"$IDENTITY_JSON")
[[ "$IDENTITY_ID" != "null" && -n "$IDENTITY_ID" ]] || { echo "ERROR: no identity id in: $IDENTITY_JSON" >&2; exit 1; }
echo "    identity: $IDENTITY_ID"

echo "==> Granting admin role in Keto"
kcurl -X PUT http://ory-keto-write:4467/admin/relation-tuples \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg id "$IDENTITY_ID" \
        '{namespace: "groups", object: "ADMIN", relation: "members", subject_id: $id}')" >/dev/null

echo "==> Minting a one-time recovery code"
RECOVERY_JSON=$(kcurl -X POST http://ory-kratos-admin:4434/admin/recovery/code \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg id "$IDENTITY_ID" '{identity_id: $id}')")

echo
echo "Done. Finish setup in a browser:"
echo "  link: $(jq -r '.recovery_link' <<<"$RECOVERY_JSON")"
echo "  code: $(jq -r '.recovery_code' <<<"$RECOVERY_JSON")"
echo "  expires: $(jq -r '.expires_at' <<<"$RECOVERY_JSON")"
echo
echo "Open the link, enter the code, set a password. You land in the portal as"
echo "the platform admin; create all further users at /admin/users."
