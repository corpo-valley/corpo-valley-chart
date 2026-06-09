#!/usr/bin/env bash
# Wire kubelet on this node to pull from cv-registry (in-cluster, plain HTTP).
# Run on EVERY node, after `helm install`.
#
# Why: kubelet resolves image hostnames via the node's /etc/resolv.conf, NOT
# cluster DNS, so `registry.<prefix>registry.svc.cluster.local` doesn't resolve
# from the node. And containerd refuses plaintext-HTTP registries unless told
# otherwise. This script captures both edits, idempotently:
#
#  1. /etc/hosts: map the registry Service DNS name -> its ClusterIP.
#  2. containerd certs.d: hosts.toml marking the registry plain-HTTP.
#     Detects microk8s and k3s automatically; pass --certs-dir for anything
#     else (the dir containerd's `config_path` points at).
#
# Usage (as root, with a kubeconfig that can read the registry Service):
#   sudo ./setup-node-registry.sh [--namespace-prefix cv-] [--certs-dir DIR]

set -euo pipefail

NSP="cv-"
CERTS_BASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace-prefix) NSP="$2"; shift 2 ;;
    --certs-dir)        CERTS_BASE="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | head -n -1 | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo)" >&2; exit 1; }

NS="${NSP}registry"
HOST="registry.${NS}.svc.cluster.local"
PORT="5000"

CLUSTER_IP=$(kubectl get svc registry -n "$NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
[[ -n "$CLUSTER_IP" ]] || { echo "Service 'registry' not found in '$NS' — install the chart first" >&2; exit 1; }
echo "registry ClusterIP = $CLUSTER_IP"

# 1. /etc/hosts
HOSTS_LINE="${CLUSTER_IP} ${HOST}"
if grep -qE "^[^#]*\s${HOST}(\s|\$)" /etc/hosts; then
  sed -i "s|^[^#]*\s${HOST}.*\$|${HOSTS_LINE}|" /etc/hosts
  echo "/etc/hosts: refreshed ${HOST} -> ${CLUSTER_IP}"
else
  printf '\n# corpo-valley in-cluster registry (kubelet pull)\n%s\n' "$HOSTS_LINE" >> /etc/hosts
  echo "/etc/hosts: added ${HOSTS_LINE}"
fi

# 2. containerd certs.d
if [[ -z "$CERTS_BASE" ]]; then
  if [[ -d /var/snap/microk8s ]]; then
    CERTS_BASE="/var/snap/microk8s/current/args/certs.d"
  elif [[ -d /var/lib/rancher/k3s ]]; then
    CERTS_BASE="/var/lib/rancher/k3s/agent/etc/containerd/certs.d"
  else
    echo "Could not detect microk8s or k3s — pass --certs-dir <containerd certs.d path>" >&2
    exit 1
  fi
fi

CERTS_DIR="${CERTS_BASE}/${HOST}:${PORT}"
mkdir -p "$CERTS_DIR"
cat > "$CERTS_DIR/hosts.toml" <<EOF
server = "http://${HOST}:${PORT}"

[host."http://${HOST}:${PORT}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
  plain_http = true
EOF
echo "containerd certs.d: wrote $CERTS_DIR/hosts.toml"

# microk8s hot-reloads certs.d; k3s needs a restart to pick it up.
if [[ "$CERTS_BASE" == /var/lib/rancher/k3s/* ]]; then
  echo "k3s detected: restart it to load the registry config (workload-disruptive):"
  echo "  sudo systemctl restart k3s    # server node"
  echo "  sudo systemctl restart k3s-agent  # agent node"
fi

echo "done. Verify: kubectl run probe --rm -i --restart=Never --image=${HOST}:${PORT}/<owner>/<repo>:latest -- true"
