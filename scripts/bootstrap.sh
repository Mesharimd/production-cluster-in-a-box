#!/usr/bin/env bash
set -euo pipefail

readonly ARGOCD_VERSION="v3.4.5"
readonly ARGOCD_NAMESPACE="argocd"
readonly ARGOCD_TIMEOUT="10m"
readonly ARGOCD_INSTALL_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly TERRAFORM_DIR="${REPO_ROOT}/terraform"
readonly KUBECONFIG_PATH="${REPO_ROOT}/kubeconfig"
readonly ROOT_APP_PATH="${REPO_ROOT}/argocd/bootstrap/root-app.yaml"

readonly TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"
readonly KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
readonly SCP_BIN="${SCP_BIN:-scp}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for required_command in \
  "$TERRAFORM_BIN" \
  "$KUBECTL_BIN" \
  "$SCP_BIN" \
  chmod \
  grep \
  mktemp \
  mv \
  rm \
  sed
do
  require_command "$required_command"
done

[[ -f "$ROOT_APP_PATH" ]] || die "root Application not found: $ROOT_APP_PATH"

elastic_ip="$("$TERRAFORM_BIN" -chdir="$TERRAFORM_DIR" output -raw elastic_ip)"
[[ "$elastic_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
  die "terraform output elastic_ip is not an IPv4 address"

scp_output="$("$TERRAFORM_BIN" -chdir="$TERRAFORM_DIR" output -raw kubeconfig_scp_command)"
scp_program=""
scp_identity_flag=""
ssh_identity=""
scp_source=""
scp_destination=""
scp_extra=""
IFS=' ' read -r \
  scp_program \
  scp_identity_flag \
  ssh_identity \
  scp_source \
  scp_destination \
  scp_extra <<<"$scp_output"

[[ "$scp_program" == "scp" ]] || die "unexpected kubeconfig scp command"
[[ "$scp_identity_flag" == "-i" ]] || die "kubeconfig scp command has no identity file"
[[ -n "$ssh_identity" && -r "$ssh_identity" ]] || die "SSH identity file is not readable"
[[ "$scp_source" == "ubuntu@${elastic_ip}:/etc/rancher/k3s/k3s.yaml" ]] || \
  die "kubeconfig scp source does not match the Elastic IP"
[[ "$scp_destination" == "./kubeconfig" && -z "$scp_extra" ]] || \
  die "unexpected kubeconfig scp destination"

umask 077
downloaded_kubeconfig="$(mktemp "${KUBECONFIG_PATH}.download.XXXXXX")"
rewritten_kubeconfig="$(mktemp "${KUBECONFIG_PATH}.rewritten.XXXXXX")"

cleanup() {
  rm -f "$downloaded_kubeconfig" "$rewritten_kubeconfig"
}
trap cleanup EXIT

printf 'Fetching kubeconfig from %s...\n' "$elastic_ip"
"$SCP_BIN" -i "$ssh_identity" "$scp_source" "$downloaded_kubeconfig"

grep -Fq 'server: https://127.0.0.1:6443' "$downloaded_kubeconfig" || \
  die "downloaded kubeconfig does not contain the expected local API endpoint"

sed \
  "s|server: https://127\\.0\\.0\\.1:6443|server: https://${elastic_ip}:6443|" \
  "$downloaded_kubeconfig" >"$rewritten_kubeconfig"

grep -Fq "server: https://${elastic_ip}:6443" "$rewritten_kubeconfig" || \
  die "failed to rewrite the kubeconfig API endpoint"

chmod 600 "$rewritten_kubeconfig"
mv "$rewritten_kubeconfig" "$KUBECONFIG_PATH"
rm -f "$downloaded_kubeconfig"
trap - EXIT

export KUBECONFIG="$KUBECONFIG_PATH"

printf 'Installing Argo CD %s...\n' "$ARGOCD_VERSION"
"$KUBECTL_BIN" create namespace "$ARGOCD_NAMESPACE" \
  --dry-run=client \
  --output=yaml | "$KUBECTL_BIN" apply -f -

"$KUBECTL_BIN" apply \
  --namespace "$ARGOCD_NAMESPACE" \
  --server-side \
  --force-conflicts \
  --filename "$ARGOCD_INSTALL_MANIFEST"

"$KUBECTL_BIN" wait \
  --for=condition=Established \
  crd/applications.argoproj.io \
  --timeout=2m

argocd_deployments=(
  argocd-applicationset-controller
  argocd-dex-server
  argocd-notifications-controller
  argocd-redis
  argocd-repo-server
  argocd-server
)

for deployment in "${argocd_deployments[@]}"; do
  "$KUBECTL_BIN" --namespace "$ARGOCD_NAMESPACE" rollout status \
    "deployment/${deployment}" \
    --timeout="$ARGOCD_TIMEOUT"
done

"$KUBECTL_BIN" --namespace "$ARGOCD_NAMESPACE" rollout status \
  statefulset/argocd-application-controller \
  --timeout="$ARGOCD_TIMEOUT"

printf 'Applying the root app-of-apps...\n'
"$KUBECTL_BIN" apply --filename "$ROOT_APP_PATH"

"$KUBECTL_BIN" --namespace "$ARGOCD_NAMESPACE" wait \
  --for=jsonpath='{.status.sync.status}'=Synced \
  application/root-app \
  --timeout="$ARGOCD_TIMEOUT"

"$KUBECTL_BIN" --namespace "$ARGOCD_NAMESPACE" wait \
  --for=jsonpath='{.status.health.status}'=Healthy \
  application/root-app \
  --timeout="$ARGOCD_TIMEOUT"

"$KUBECTL_BIN" --namespace "$ARGOCD_NAMESPACE" get application root-app
printf 'Argo CD bootstrap complete. Kubeconfig: %s\n' "$KUBECONFIG_PATH"
