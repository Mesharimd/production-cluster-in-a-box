# Sealed Grafana credentials

Sealed Secrets keeps only public-key-encrypted values in Git. The controller's private key never leaves the cluster, and the Grafana password must never be written into this repository as a Kubernetes `Secret`, Helm value, shell argument, or temporary plaintext file.

## Secret contract

The final Grafana configuration expects a generated Secret with this exact contract:

- name: `grafana-admin-credentials`
- namespace: `monitoring`
- keys: `admin-user` and `admin-password`

The SealedSecret is strict-scoped to that name and namespace. Renaming or moving it requires resealing.

This is a commented example only. The placeholders are not valid ciphertext and this block is intentionally not a deployable manifest:

```yaml
# apiVersion: bitnami.com/v1alpha1
# kind: SealedSecret
# metadata:
#   name: grafana-admin-credentials
#   namespace: monitoring
# spec:
#   encryptedData:
#     admin-user: <SEALED_CIPHERTEXT>
#     admin-password: <SEALED_CIPHERTEXT>
#   template:
#     metadata:
#       name: grafana-admin-credentials
#       namespace: monitoring
#     type: Opaque
```

## Generate the real manifest

Wait until P3 commit 5 is live and `deployment/sealed-secrets-controller` is Ready. Install the `kubeseal` CLI locally, keep the fetched kubeconfig in the repository's ignored `./kubeconfig` file, and run from the repository root:

```bash
bash
set -euo pipefail
export KUBECONFIG="$PWD/kubeconfig"
kubectl -n sealed-secrets rollout status deployment/sealed-secrets-controller --timeout=5m

read -r -s -p "Grafana admin password: " GRAFANA_ADMIN_PASSWORD
printf '\n'
trap 'unset GRAFANA_ADMIN_PASSWORD' EXIT

printf '%s' "$GRAFANA_ADMIN_PASSWORD" \
| kubectl create secret generic grafana-admin-credentials \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-file=admin-password=/dev/stdin \
  --dry-run=client \
  --output yaml \
| kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  --format yaml \
> argocd/apps/grafana-admin-sealedsecret.yaml

kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  --validate \
< argocd/apps/grafana-admin-sealedsecret.yaml

if rg -n 'kind: Secret|stringData:|adminPassword:' argocd/apps/; then
  printf 'Refusing to continue: an unsealed secret pattern was found.\n' >&2
  exit 1
fi

unset GRAFANA_ADMIN_PASSWORD
trap - EXIT
exit
```

The pipeline keeps the unsealed Secret off disk and passes the password through standard input rather than a process argument. The password is read silently and is not placed in shell history. Do not enable shell tracing while running these commands. The final `rg` guard must find no unsealed Secret patterns. It is normal for the sealed file to contain the key names `admin-user` and `admin-password`; their values must be long encrypted strings under `spec.encryptedData`.

Do not push the generated file by itself. Follow [`p3-rollout.md`](p3-rollout.md): add it to the still-local Grafana ingress commit with `git commit --amend --no-edit`, then push that amended final app commit.

## Recovery boundary

The controller's private sealing keys live in a Kubernetes Secret in the cluster. Existing encrypted Git values cannot be decrypted after those keys are lost. P4's etcd backup therefore becomes part of the recovery chain; until P4 is complete and tested, do not treat the sealed value as independently recoverable.
