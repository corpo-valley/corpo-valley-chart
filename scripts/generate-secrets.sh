#!/usr/bin/env bash
# Generate every Secret this chart expects, optionally seal each one with
# kubeseal against the current cluster's controller.
#
# Usage:
#   ./generate-secrets.sh \
#     --namespace-prefix cv- \
#     --smtp-uri "smtps://user:pass@smtp.example.com:465/?disable_starttls=false" \
#     --cloudflare-credentials ./credentials.json \
#     --output ./out/secrets
#
# Optional flags:
#   --seal                 also seal each output with kubeseal
#   --restore-env FILE     reuse passwords from a prior generate-secrets.sh run
#                          (keeps DSN strings stable across regenerations)
#
# Writes:
#   ./out/secrets/plain/<name>.yaml      (every Secret, before sealing)
#   ./out/secrets/sealed/<name>.sealed.yaml (only when --seal is passed)
#   ./out/secrets/secrets.local.env      passwords (for --restore-env reuse)

set -euo pipefail

NSP="cv-"
SMTP_URI=""
CFD_CREDS=""
OUT="./out/secrets"
SEAL=false
RESTORE_ENV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace-prefix)        NSP="$2"; shift 2 ;;
    --smtp-uri)                SMTP_URI="$2"; shift 2 ;;
    --cloudflare-credentials)  CFD_CREDS="$2"; shift 2 ;;
    --output)                  OUT="$2"; shift 2 ;;
    --seal)                    SEAL=true; shift ;;
    --restore-env)             RESTORE_ENV="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | head -n -1 | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUT/plain"
$SEAL && mkdir -p "$OUT/sealed"

rand() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"; }
randb64() { openssl rand -base64 32 | tr -d '\n'; }  # exactly 32 bytes, base64 — AES-256 keys

if [[ -n "$RESTORE_ENV" ]]; then
  # shellcheck source=/dev/null
  source "$RESTORE_ENV"
fi

: "${POSTGRES_PASSWORD:=$(rand 32)}"
: "${KRATOS_PASSWORD:=$(rand 32)}"
: "${HYDRA_PASSWORD:=$(rand 32)}"
: "${KETO_PASSWORD:=$(rand 32)}"
: "${PORTAL_PASSWORD:=$(rand 32)}"
: "${KRATOS_SECRETS_COOKIE:=$(rand 32)}"
: "${KRATOS_SECRETS_CIPHER:=$(rand 32)}"   # exactly 32 chars
: "${HYDRA_SECRETS_SYSTEM:=$(rand 32)}"
: "${HYDRA_SECRETS_COOKIE:=$(rand 32)}"
: "${GITEA_CLIENT_SECRET:=$(rand 32)}"
: "${GITEA_SECRET_KEY:=$(rand 64)}"
: "${GITEA_INTERNAL_TOKEN:=$(rand 105)}"
: "${GITEA_ADMIN_TOKEN:=unset-mint-post-install}"
: "${PORTAL_SECRET_KEY:=$(randb64)}"        # base64 32 bytes — AES-256, portal refuses to boot otherwise
: "${INTERNAL_WEBHOOK_SECRET:=$(rand 48)}"

cat >"$OUT/secrets.local.env" <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
KRATOS_PASSWORD=$KRATOS_PASSWORD
HYDRA_PASSWORD=$HYDRA_PASSWORD
KETO_PASSWORD=$KETO_PASSWORD
PORTAL_PASSWORD=$PORTAL_PASSWORD
KRATOS_SECRETS_COOKIE=$KRATOS_SECRETS_COOKIE
KRATOS_SECRETS_CIPHER=$KRATOS_SECRETS_CIPHER
HYDRA_SECRETS_SYSTEM=$HYDRA_SECRETS_SYSTEM
HYDRA_SECRETS_COOKIE=$HYDRA_SECRETS_COOKIE
GITEA_CLIENT_SECRET=$GITEA_CLIENT_SECRET
GITEA_SECRET_KEY=$GITEA_SECRET_KEY
GITEA_INTERNAL_TOKEN=$GITEA_INTERNAL_TOKEN
GITEA_ADMIN_TOKEN=$GITEA_ADMIN_TOKEN
PORTAL_SECRET_KEY=$PORTAL_SECRET_KEY
INTERNAL_WEBHOOK_SECRET=$INTERNAL_WEBHOOK_SECRET
EOF

emit_secret() {
  local name="$1" ns="$2"; shift 2
  local file="$OUT/plain/${name}.yaml"
  {
    echo "apiVersion: v1"
    echo "kind: Secret"
    echo "metadata:"
    echo "  name: $name"
    echo "  namespace: $ns"
    echo "type: Opaque"
    echo "stringData:"
    while [[ $# -gt 0 ]]; do
      local key="$1" val="$2"; shift 2
      printf '  %s: %q\n' "$key" "$val"
    done
  } >"$file"

  if $SEAL; then
    local out="$OUT/sealed/${name}.sealed.yaml"
    kubeseal \
      --controller-name=sealed-secrets-controller \
      --controller-namespace=kube-system \
      --format=yaml \
      <"$file" >"$out"
    echo "sealed -> $out"
  else
    echo "wrote  -> $file"
  fi
}

NS_ORY="${NSP}ory"
NS_PORTAL="${NSP}portal"
NS_GITEA="${NSP}gitea"
NS_GITEA_RUNNERS="${NSP}gitea-runners"
NS_CLOUDFLARED="${NSP}cloudflared"

PG_HOST="ory-postgres.${NS_ORY}.svc.cluster.local"

emit_secret ory-db-credentials "$NS_ORY" \
  POSTGRES_PASSWORD "$POSTGRES_PASSWORD" \
  KRATOS_PASSWORD   "$KRATOS_PASSWORD" \
  HYDRA_PASSWORD    "$HYDRA_PASSWORD" \
  KETO_PASSWORD     "$KETO_PASSWORD" \
  PORTAL_PASSWORD   "$PORTAL_PASSWORD" \
  DSN_KRATOS "postgres://kratos:${KRATOS_PASSWORD}@${PG_HOST}:5432/kratos?sslmode=disable" \
  DSN_HYDRA  "postgres://hydra:${HYDRA_PASSWORD}@${PG_HOST}:5432/hydra?sslmode=disable&max_conns=20&max_idle_conns=4" \
  DSN_KETO   "postgres://keto:${KETO_PASSWORD}@${PG_HOST}:5432/keto?sslmode=disable&max_conns=20&max_idle_conns=4"

emit_secret ory-kratos-secrets "$NS_ORY" \
  SECRETS_COOKIE "$KRATOS_SECRETS_COOKIE" \
  SECRETS_CIPHER "$KRATOS_SECRETS_CIPHER"

emit_secret ory-hydra-secrets "$NS_ORY" \
  SECRETS_SYSTEM "$HYDRA_SECRETS_SYSTEM" \
  SECRETS_COOKIE "$HYDRA_SECRETS_COOKIE"

emit_secret ory-hydra-clients "$NS_ORY" \
  GITEA_CLIENT_SECRET "$GITEA_CLIENT_SECRET"

[[ -n "$SMTP_URI" ]] && emit_secret kratos-smtp "$NS_ORY" \
  COURIER_SMTP_CONNECTION_URI "$SMTP_URI"

emit_secret portal-db "$NS_PORTAL" \
  DATABASE_URL "postgres://portal:${PORTAL_PASSWORD}@${PG_HOST}:5432/portal?sslmode=disable"

emit_secret portal-platform-secrets "$NS_PORTAL" \
  PORTAL_SECRET_KEY       "$PORTAL_SECRET_KEY" \
  INTERNAL_WEBHOOK_SECRET "$INTERNAL_WEBHOOK_SECRET"

emit_secret gitea-admin "$NS_PORTAL" \
  GITEA_URL "http://gitea.${NS_GITEA}.svc.cluster.local" \
  GITEA_ADMIN_USER "cvportal" \
  GITEA_ADMIN_TOKEN "$GITEA_ADMIN_TOKEN"

emit_secret gitea-secrets "$NS_GITEA" \
  SECRET_KEY     "$GITEA_SECRET_KEY" \
  INTERNAL_TOKEN "$GITEA_INTERNAL_TOKEN"

emit_secret runner-registration-token "$NS_GITEA_RUNNERS" \
  GITEA_RUNNER_REGISTRATION_TOKEN "${GITEA_RUNNER_TOKEN:-unset-mint-post-install}"

if [[ -n "$CFD_CREDS" ]]; then
  CFD_JSON=$(cat "$CFD_CREDS")
  emit_secret cloudflare-tunnel-credentials "$NS_CLOUDFLARED" \
    credentials.json "$CFD_JSON"
fi

echo
echo "Done. Outputs in $OUT/. Passwords saved to $OUT/secrets.local.env — keep it safe."
$SEAL && echo "Sealed manifests in $OUT/sealed/ are safe to commit to git."
