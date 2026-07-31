# P3 staged rollout

P3 is deliberately split into seven app commits. Push and verify one commit at a time. Argo CD is the only deployment path: none of the commands below applies, patches, or deletes cluster resources.

## Before the first push

Run from the repository root:

```bash
export KUBECONFIG="$PWD/kubeconfig"
git status --short
git log --reverse --format='%h %s' 802a3ba..HEAD
kubectl get nodes
kubectl -n argocd get application root-app
```

The log must show exactly these seven app commits in this order:

1. ingress-nginx
2. cert-manager and the two ClusterIssuers
3. the trimmed monitoring stack
4. Loki, Promtail, and the Grafana datasource
5. the sealed-secrets controller and sealing workflow
6. the demo application
7. the Grafana ingress and sealed-admin-secret reference

For each step, copy the corresponding full SHA from `git rev-list --reverse 802a3ba..HEAD` and push only that commit:

```bash
git push origin <COMMIT_SHA>:main
```

Wait for `root-app` and the new child Application to report `Synced` and `Healthy` before continuing. The root application polls Git approximately every three minutes, so a short delay is expected.

The final tree also has an explicit reconciliation order. These waves do not replace the staged checks; they prevent CRD and workload dependency races when a P2 cluster reconciles every P3 manifest at once:

| Wave | Root-app resource |
| ---: | --- |
| 0 | `monitoring` and `demo` Namespaces |
| 10, 20 | ingress-nginx, then cert-manager Applications |
| 40–42 | Loki, Promtail, then the Grafana datasource |
| 49, 50 | SealedSecret CRD, then its controller Application |
| 55 | Operator-generated Grafana SealedSecret |
| 60, 61 | kube-prometheus-stack with Grafana enabled, then Grafana Ingress |
| 70, 71 | Demo workload, then demo Ingress |

This ordering does not make a SealedSecret portable. Its ciphertext is bound to the controller key that sealed it. On a fresh cluster, restore the original Sealed Secrets key before reconciliation, or wait for the new controller, reseal the Grafana credential against its certificate, and push the replacement encrypted manifest in a reviewed recovery commit. Until one of those actions is complete, Grafana cannot start even if root-app reconciliation advances past wave 55. See the recovery boundary in [`sealed-secrets.md`](sealed-secrets.md).

## 1. ingress-nginx

Push commit 1, then verify:

```bash
kubectl -n argocd get application ingress-nginx
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=5m
kubectl -n ingress-nginx get service ingress-nginx-controller -o wide
kubectl -n kube-system get pods | grep svclb-ingress-nginx-controller
curl --head http://demo.meshari.xyz
```

The controller Service must be `LoadBalancer` and k3s must run a matching `svclb-...` pod. Depending on node-address detection, Service status can show an internal node address rather than the NATed Elastic IP; the public DNS `curl` is the authoritative end-to-end check. A plain HTTP `404` is successful at this stage because no application Ingress exists yet.

Design decision: k3s was installed with Traefik disabled but its [built-in ServiceLB](https://docs.k3s.io/networking/networking-services#service-load-balancer) remains enabled. ServiceLB claims host ports 80 and 443 for the ingress-nginx `LoadBalancer` Service, so no AWS load balancer, `hostNetwork`, or manually managed NodePort is needed. This preserves the Elastic IP and the existing EC2 security-group boundary.

Lifecycle caveat: ingress-nginx is pinned to its [final chart, `4.15.1`](https://github.com/kubernetes/ingress-nginx/releases/tag/helm-chart-4.15.1). The [upstream project was retired](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/) in March 2026 and this final release lists Kubernetes support through 1.35, while this cluster runs k3s 1.36. It remains here because P3 explicitly requires ingress-nginx, but it is an accepted demo-only compatibility risk and should be migrated before treating the stack as a long-lived production platform.

## 2. cert-manager and ClusterIssuers

Push commit 2, then verify:

```bash
kubectl -n argocd get application cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=5m
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=5m
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=5m
kubectl get clusterissuer letsencrypt-staging letsencrypt-prod
```

Both issuers must show `READY=True`. They use separate ACME account-key Secrets and solve HTTP-01 challenges through `ingressClassName: nginx`. No certificate requests are created yet.

## 3. trimmed kube-prometheus-stack

Push commit 3, then verify:

```bash
kubectl -n argocd get application kube-prometheus-stack
kubectl -n monitoring get pods
kubectl -n monitoring wait pod --all --for=condition=Ready --timeout=10m
kubectl -n monitoring wait pod/grafana-pvc-binder --for=condition=Ready --timeout=5m
kubectl -n monitoring get prometheus
kubectl -n monitoring get alertmanager # Expected: no resources found.
kubectl -n monitoring get deployment grafana # Expected: no resources found until commit 7.
kubectl -n monitoring get pvc
kubectl top pods -n monitoring
kubectl top node
```

Every workload must be ready, and both the Prometheus PVC and the empty reserved `grafana` PVC must be bound before continuing. k3s local-path storage uses `WaitForFirstConsumer`, so commits 3–6 include a tiny `grafana-pvc-binder` Pod that mounts the claim read-only without initializing Grafana's database. The Grafana Deployment is intentionally absent at this stage. Compare actual memory use with the documented P3 resource budget below; do not proceed if the node is under memory pressure.

### Four-gigabyte design budget

The full default kube-prometheus-stack is not safe on this 4 GiB node. Commit 3 keeps the useful metrics path while removing or deferring these costs:

- One Prometheus replica and one shard: this is a single-node demo, so extra replicas cannot provide real availability.
- Alertmanager and alerting rules disabled: there is no P3 notification route, and loading or evaluating a dead-end alert pipeline would spend resources without demonstrating delivery.
- Admission webhooks disabled: version-pinned Helm rendering plus kubeconform is the GitOps validation gate; this avoids another deployment and hook jobs.
- Only the API server and CoreDNS control-plane monitors retained: k3s embeds etcd, scheduler, controller-manager, and proxy differently from the standalone endpoints assumed by the chart.
- Recording rules reduced to the container/resource and node-exporter series used by the retained dashboards; broad alert and platform rule groups are disabled.
- kube-state-metrics restricted to 11 Kubernetes object collectors instead of watching every supported object.
- Self-monitoring targets, Windows monitoring, Thanos, Grafana tests, and the Grafana Alertmanager datasource disabled.
- Scrape and evaluation intervals set to 60 seconds instead of collecting demo data at a production-scale cadence.
- Seven-day retention bounded by a 6 GiB size ceiling on an 8 GiB `local-path` PVC, using the storage provisioner built into k3s.
- A separate empty 1 GiB `grafana` claim is reserved in commit 3 and remains desired across commit-7 rollback. Its Argo annotations also prevent accidental pruning or Application-deletion cleanup. A read-only, non-root binder Pod forces `local-path` to provision the `WaitForFirstConsumer` claim and is removed in commit 7.
- Grafana deferred until commit 7: this avoids a random bootstrap password being persisted in its SQLite database before sealed-secrets is available. Commit 7 removes the binder, mounts the reserved claim in Grafana, and starts Grafana for the first time with the sealed admin credentials already referenced.

Steady-state explicit container budgets are:

| Component | CPU request | CPU limit | Memory request | Memory limit |
| --- | ---: | ---: | ---: | ---: |
| Prometheus | 200m | 750m | 512 MiB | 768 MiB |
| Prometheus config reloader | 10m | 50m | 16 MiB | 48 MiB |
| Prometheus Operator | 50m | 200m | 48 MiB | 128 MiB |
| kube-state-metrics | 25m | 100m | 32 MiB | 96 MiB |
| node-exporter | 20m | 100m | 16 MiB | 64 MiB |
| Base monitoring subtotal | 305m | 1.2 CPU | 624 MiB | 1,104 MiB |
| Temporary PVC binder, commits 3–6 only | 5m | 25m | 8 MiB | 16 MiB |
| **Commit 3 monitoring subtotal** | **310m** | **1.225 CPU** | **632 MiB** | **1,120 MiB** |
| Grafana, added in commit 7 | 75m | 300m | 128 MiB | 320 MiB |
| Two Grafana sidecars, added in commit 7 | 20m | 100m | 32 MiB | 96 MiB |
| **Final monitoring total, binder removed** | **400m** | **1.6 CPU** | **784 MiB** | **1,520 MiB** |

The Prometheus init reloader is transient and separately bounded at 16/48 MiB. When Grafana starts in commit 7, its ownership init container is separately bounded at 8/32 MiB. Across the complete P3 stack, the steady declared pod budget is:

| P3 group | CPU request | CPU limit | Memory request | Memory limit |
| --- | ---: | ---: | ---: | ---: |
| ingress-nginx | 100m | 500m | 128 MiB | 256 MiB |
| cert-manager controllers | 40m | 250m | 160 MiB | 320 MiB |
| monitoring | 400m | 1.6 CPU | 784 MiB | 1,520 MiB |
| Loki and Promtail | 125m | 700m | 320 MiB | 640 MiB |
| sealed-secrets | 50m | 200m | 64 MiB | 128 MiB |
| demo | 20m | 100m | 32 MiB | 64 MiB |
| **P3 steady total** | **735m** | **3.35 CPU** | **1,488 MiB** | **2,928 MiB** |

Requests are the scheduling budget; limits are ceilings, not reservations. The 1.45 GiB request total leaves about 2.55 GiB for k3s, Argo CD, ServiceLB, the OS, and bursts. Simultaneous steady memory ceilings leave about 1.14 GiB of physical headroom; CPU limits intentionally overcommit the two vCPUs because CPU throttles instead of causing an OOM. Admission/startup jobs, ACME solver pods, and init containers are separately limited and occur in different rollout stages. The operator must still stop if `kubectl top node` reports sustained memory pressure before logging is added.

## 4. Loki, Promtail, and Grafana datasource

Push commit 4, then verify:

```bash
kubectl -n argocd get application loki promtail
kubectl -n logging get pods,pvc
kubectl -n monitoring get configmap loki-grafana-datasource
kubectl -n logging logs daemonset/promtail --tail=50
kubectl top pods -n logging
```

Loki must have one ready single-binary pod, Promtail must have one ready pod on the single node, and the datasource ConfigMap must exist in `monitoring`. Promtail is deliberately pinned even though it is in maintenance/EOL status because P3 requires it; Grafana Alloy is the future migration target.

The logging design uses Loki chart `18.7.1` in its current `Monolithic` mode (the chart's name for a single binary), filesystem-backed TSDB v13, one 5 GiB `local-path` PVC, and seven-day compactor retention. Gateway, Memcached caches, canary, tests, rules sidecar, MinIO, and every scalable/distributed component are disabled. Grafana and Promtail talk directly to `loki.logging.svc.cluster.local:3100`.

Single-tenant trust boundary: Loki authentication is disabled and its Service remains internal-only `ClusterIP`, with no Ingress or NodePort. That is acceptable only while every cluster workload is trusted; Kubernetes namespaces alone are not a network security boundary. Before adding untrusted workloads or tenants, put Loki behind an authenticated gateway and NetworkPolicy, or enable Loki multi-tenancy.

Loki and Promtail request 125m CPU / 320 MiB memory together and are limited to 700m CPU / 640 MiB memory. Promtail chart `6.17.1` is explicitly deprecated and its image is pinned to `3.6.11`; [Promtail reached end of life](https://grafana.com/docs/loki/latest/send-data/promtail/) on March 2, 2026. It is present only because P3 requires it, and the next logging-agent change must migrate this DaemonSet to Grafana Alloy.

## 5. sealed-secrets

Push commit 5, then verify:

```bash
kubectl -n argocd get application sealed-secrets
kubectl -n sealed-secrets rollout status deployment/sealed-secrets-controller --timeout=5m
kubectl get customresourcedefinition sealedsecrets.bitnami.com
```

The controller is pinned to chart `2.19.1` / controller `0.38.4`, with one replica requesting 50m CPU / 64 MiB and limited to 200m CPU / 128 MiB. Metrics rules and ServiceMonitor resources are disabled for this small node. The root app owns the version-matched CRD at wave 49; the controller chart skips its duplicate CRD and starts at wave 50. Read [`sealed-secrets.md`](sealed-secrets.md) before the final Grafana step. Do not commit an unsealed Kubernetes Secret or a plaintext password.

## 6. demo application

Push commit 6, then verify the staging certificate and application:

```bash
kubectl -n demo rollout status deployment/demo --timeout=5m
kubectl -n demo get ingress,certificate,certificaterequest,challenge
kubectl -n demo wait certificate/demo-tls --for=condition=Ready --timeout=10m
curl --insecure https://demo.meshari.xyz
openssl s_client -connect demo.meshari.xyz:443 -servername demo.meshari.xyz </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

The page must load and name the stack. The certificate should be Ready but intentionally untrusted because it was issued by Let's Encrypt staging.

The demo is one unprivileged nginx pod pinned by image tag and multi-architecture digest. It requests 20m CPU / 32 MiB and is limited to 100m CPU / 64 MiB; it has no service-account token and serves only the Git-tracked ConfigMap page.

## 7. Grafana ingress and sealed admin credentials

After commit 5 is live, create the real encrypted Grafana manifest by following [`sealed-secrets.md`](sealed-secrets.md). Save it as `argocd/apps/grafana-admin-sealedsecret.yaml`. Before pushing commit 7, add that encrypted file to the still-local final commit:

```bash
kubeconform \
  -strict \
  -summary \
  -skip CustomResourceDefinition \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  argocd/
git add argocd/apps/grafana-admin-sealedsecret.yaml
git diff --cached --check
rg -n 'kind: Secret|stringData:|adminPassword:' argocd/apps/
git commit --amend --no-edit
git show --stat --oneline HEAD
```

Kubeconform and `git diff --cached --check` must pass after the generated SealedSecret is staged, and the `rg` command must return no matches before the commit is amended. Recompute commit 7's SHA after the amend, then push that SHA. This keeps the real SealedSecret and the Grafana switch atomic without adding an eighth app commit. The generated resource's required wave 55 is added by the sealing pipeline; commit 7 moves the monitoring Application to wave 60 and the Grafana Ingress to wave 61.

Verify:

```bash
kubectl -n monitoring get sealedsecret grafana-admin-credentials
kubectl -n monitoring get pod grafana-pvc-binder # Expected: no resources found.
kubectl -n monitoring get secret grafana-admin-credentials \
  --output go-template='{{range $key, $value := .data}}{{$key}}{{"\n"}}{{end}}'
kubectl -n monitoring rollout status deployment/grafana --timeout=5m
kubectl -n monitoring get ingress,certificate,certificaterequest,challenge
kubectl -n monitoring wait certificate/grafana-tls --for=condition=Ready --timeout=10m
curl --insecure --head https://grafana.meshari.xyz/login
openssl s_client -connect grafana.meshari.xyz:443 -servername grafana.meshari.xyz </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

The generated Secret command must print only `admin-password` and `admin-user`, and the temporary binder Pod must be absent. Grafana must become Ready and its login page must load with the staging certificate. Grafana was disabled in commit 3, so this is its first database initialization on the already-reserved claim: the Deployment reads both admin values from `grafana-admin-credentials`, and no temporary chart-generated password is ever persisted.

## Promote staging certificates to production

Only after both staging certificates are Ready and both HTTPS routes work, change the issuer annotation in exactly these two files from `letsencrypt-staging` to `letsencrypt-prod`:

- `argocd/apps/demo.yaml`
- `argocd/apps/grafana-ingress.yaml`

Commit and push the promotion:

```bash
bash
set -euo pipefail
git add argocd/apps/demo.yaml argocd/apps/grafana-ingress.yaml
git diff --cached --check
if rg -n 'kind: Secret|stringData:|adminPassword:' argocd/apps/; then
  echo "Refusing to commit an unsealed Secret or plaintext password." >&2
  exit 1
fi
git commit -m "feat: promote public certificates to production"
git push origin main
kubectl -n demo wait certificate/demo-tls --for=condition=Ready --timeout=10m
kubectl -n monitoring wait certificate/grafana-tls --for=condition=Ready --timeout=10m
curl --fail --silent --show-error https://demo.meshari.xyz >/dev/null
curl --fail --silent --show-error https://grafana.meshari.xyz/login >/dev/null
exit
```

If cert-manager does not replace an existing staging certificate after the issuer annotation changes, change each Ingress TLS `secretName` to a new `-prod-tls` name, then create a separate follow-up fix commit through the same gate:

```bash
bash
set -euo pipefail
git add argocd/apps/demo.yaml argocd/apps/grafana-ingress.yaml
git diff --cached --check
if rg -n 'kind: Secret|stringData:|adminPassword:' argocd/apps/; then
  echo "Refusing to commit an unsealed Secret or plaintext password." >&2
  exit 1
fi
git commit -m "fix: use production TLS secret names"
git push origin main
kubectl -n demo wait certificate/demo-prod-tls --for=condition=Ready --timeout=10m
kubectl -n monitoring wait certificate/grafana-prod-tls --for=condition=Ready --timeout=10m
curl --fail --silent --show-error https://demo.meshari.xyz >/dev/null
curl --fail --silent --show-error https://grafana.meshari.xyz/login >/dev/null
exit
```

The promotion commit is already remote at that point, so do not amend it or force-push it. Do not delete a Secret with kubectl.

## Rollback

During the staged rollout, stop immediately when a verification fails. Local `main` remains at commit 7 while the remote advances one SHA at a time, so never create or push a rollback from local `main`. Build the revert from the actual remote tip in an isolated temporary worktree:

```bash
bash
set -euo pipefail
P3_ROLLBACK_TARGET_SHA=<FAILED_APP_COMMIT_SHA>
git fetch origin main

P3_ROLLBACK_ROOT="$(mktemp -d)"
P3_ROLLBACK_WORKTREE="$P3_ROLLBACK_ROOT/repo"
git worktree add --detach "$P3_ROLLBACK_WORKTREE" origin/main

git -C "$P3_ROLLBACK_WORKTREE" merge-base --is-ancestor \
  "$P3_ROLLBACK_TARGET_SHA" HEAD
git -C "$P3_ROLLBACK_WORKTREE" revert --no-commit "$P3_ROLLBACK_TARGET_SHA"
git -C "$P3_ROLLBACK_WORKTREE" diff --cached --check
if rg -n 'kind: Secret|stringData:|adminPassword:' \
  "$P3_ROLLBACK_WORKTREE/argocd/apps/"; then
  echo "Refusing to commit an unsealed Secret or plaintext password." >&2
  exit 1
fi
git -C "$P3_ROLLBACK_WORKTREE" commit \
  -m "revert: roll back P3 app $P3_ROLLBACK_TARGET_SHA"
git -C "$P3_ROLLBACK_WORKTREE" push origin HEAD:main

git worktree remove "$P3_ROLLBACK_WORKTREE"
rmdir "$P3_ROLLBACK_ROOT"
unset P3_ROLLBACK_TARGET_SHA P3_ROLLBACK_WORKTREE P3_ROLLBACK_ROOT
exit
```

Replace `<FAILED_APP_COMMIT_SHA>` with the exact app commit that failed, then watch reconciliation with `kubectl -n argocd get application root-app --watch`. The ancestor check proves that target is part of the deployed remote history, while the revert itself is based on current `origin/main`, so later local commits cannot be pushed accidentally. If the check or revert fails, the command stops and preserves the temporary worktree for inspection; do not force the push.

Argo CD will reconcile the revert and prune resources owned by the reverted child Application. Reverting commit 7 disables Grafana, restores the read-only binder Pod, and keeps its `grafana` PVC desired by commit 3; `Prune=false,Delete=false` provides a second protection boundary. Verify the binder becomes Ready and the claim remains `Bound`. Reverting commit 3 removes the monitoring Application, but the root-owned `monitoring` Namespace and protected claims are retained so namespace garbage collection cannot erase their data. Root app may then report that pruning was skipped; that is the expected retention signal, not drift to repair with `kubectl apply`, `kubectl edit`, or `kubectl delete`.

Treat full state removal as a separate, destructive teardown. Back up Prometheus and Grafana first, then use a reviewed Git commit to remove the Namespace and PVC protection annotations while those resources are still desired and let Argo CD sync that change before reverting commit 3. Before removing the Loki app, likewise back up any state that must survive. Rollback of configuration is preferred to deleting stateful storage.

After the entire stack is live, first revert any later certificate-promotion or follow-up fix commits, newest first. Those commits modify the demo and Grafana Ingresses and must be removed before reverting the original app commits that introduced those resources. Then use the same isolated-worktree procedure one app at a time in reverse order (Grafana ingress, demo, sealed-secrets, logging, monitoring, cert-manager, ingress-nginx). Set `P3_ROLLBACK_TARGET_SHA` to each original app commit SHA in turn; do not target the new revert commit at remote HEAD. Never remove cert-manager while TLS Ingresses still depend on it, and never remove ingress-nginx while HTTP-01 challenges or public routes remain.
