#!/usr/bin/env bash
# Print the SPKI sha256 pin of the cluster's sealed-secrets controller cert,
# in the exact format the portal's SEALED_SECRETS_CERT_SHA256 env expects
# (lowercase hex over the cert's SubjectPublicKeyInfo DER).
#
# Put the output in your values file:
#   cluster:
#     sealedSecretsCertSha256: <output>
#
# Usage:
#   ./print-cert-pin.sh [--controller-name NAME] [--controller-namespace NS]
#
# Requires: kubeseal, openssl, a kubeconfig pointed at the target cluster.

set -euo pipefail

NAME="sealed-secrets-controller"
NS="kube-system"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --controller-name)      NAME="$2"; shift 2 ;;
    --controller-namespace) NS="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | head -n -1 | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

kubeseal --fetch-cert --controller-name="$NAME" --controller-namespace="$NS" \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -hex \
  | awk '{print $NF}'
