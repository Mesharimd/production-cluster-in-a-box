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

## 1. ingress-nginx

Push commit 1, then verify:

```bash
kubectl -n argocd get application ingress-nginx
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=5m
kubectl -n ingress-nginx get service ingress-nginx-controller -o wide
kubectl -n kube-system get pods | grep svclb-ingress-nginx-controller
curl --head http://demo.meshari.xyz
```

The controller Service must be `LoadBalancer`, its external address must be the EC2 Elastic IP, and k3s must run a matching `svclb-...` pod. A plain HTTP `404` is a successful routing check at this stage because no application Ingress exists yet.

Design decision: k3s was installed with Traefik disabled but its built-in ServiceLB remains enabled. ServiceLB claims host ports 80 and 443 for the ingress-nginx `LoadBalancer` Service, so no AWS load balancer, `hostNetwork`, or manually managed NodePort is needed. This preserves the Elastic IP and the existing EC2 security-group boundary.

Lifecycle caveat: ingress-nginx is pinned to its final chart, `4.15.1`. The upstream project was retired in March 2026 and this final release lists Kubernetes support through 1.35, while this cluster runs k3s 1.36. It remains here because P3 explicitly requires ingress-nginx, but it is an accepted demo-only compatibility risk and should be migrated before treating the stack as a long-lived production platform.

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
kubectl -n monitoring get prometheus,alertmanager
kubectl -n monitoring get deployment grafana # Expected: no resources found until commit 7.
kubectl -n monitoring get pvc
kubectl top pods -n monitoring
kubectl top node
```

Every workload must be ready and the Prometheus PVC must be bound before continuing. Grafana is intentionally absent at this stage. Compare actual memory use with the documented P3 resource budget below; do not proceed if the node is under memory pressure.

### Four-gigabyte design budget

The full default kube-prometheus-stack is not safe on this 4 GiB node. Commit 3 keeps the useful metrics path while removing or deferring these costs:

- One Prometheus replica and one shard: this is a single-node demo, so extra replicas cannot provide real availability.
- Alertmanager disabled: there is no P3 notification route, and loading an idle alert pipeline would spend memory without demonstrating delivery.
- Admission webhooks disabled: version-pinned Helm rendering plus kubeconform is the GitOps validation gate; this avoids another deployment and hook jobs.
- Only the API server and CoreDNS control-plane monitors retained: k3s embeds etcd, scheduler, controller-manager, and proxy differently from the standalone endpoints assumed by the chart.
- Recording rules reduced to the container/resource and node-exporter series used by the retained dashboards; broad alert and platform rule groups are disabled.
- kube-state-metrics restricted to 11 Kubernetes object collectors instead of watching every supported object.
- Self-monitoring targets, Windows monitoring, Thanos, Grafana tests, and the Grafana Alertmanager datasource disabled.
- Scrape and evaluation intervals set to 60 seconds instead of collecting demo data at a production-scale cadence.
- Seven-day retention bounded by a 6 GiB size ceiling on an 8 GiB `local-path` PVC, using the storage provisioner built into k3s.
- Grafana deferred until commit 7: this avoids a random bootstrap password being persisted in its SQLite database before sealed-secrets is available. Commit 7 creates its separate 1 GiB PVC and starts Grafana for the first time with the sealed admin credentials already referenced.

Steady-state explicit container budgets are:

| Component | CPU request | CPU limit | Memory request | Memory limit |
| --- | ---: | ---: | ---: | ---: |
| Prometheus | 200m | 750m | 512 MiB | 768 MiB |
| Prometheus config reloader | 10m | 50m | 16 MiB | 48 MiB |
| Prometheus Operator | 50m | 200m | 48 MiB | 128 MiB |
| kube-state-metrics | 25m | 100m | 32 MiB | 96 MiB |
| node-exporter | 20m | 100m | 16 MiB | 64 MiB |
| **Commit 3 monitoring subtotal** | **305m** | **1.2 CPU** | **624 MiB** | **1,104 MiB** |
| Grafana, added in commit 7 | 75m | 300m | 128 MiB | 320 MiB |
| Two Grafana sidecars, added in commit 7 | 20m | 100m | 32 MiB | 96 MiB |
| **Final monitoring total** | **400m** | **1.6 CPU** | **784 MiB** | **1,520 MiB** |

The Grafana ownership init container and Prometheus init reloader are transient and separately bounded at 8/32 MiB and 16/48 MiB respectively. Requests are the scheduling budget; limits are ceilings, not reserved memory. After all P3 apps, the declared steady-state P3 requests total approximately 1.45 GiB, leaving the rest for k3s, Argo CD, the OS, and bursts. The operator must still stop if `kubectl top node` reports sustained memory pressure before logging is added.

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

Loki and Promtail request 125m CPU / 320 MiB memory together and are limited to 700m CPU / 640 MiB memory. Promtail chart `6.17.1` is explicitly deprecated and its image is pinned to `3.6.11`; Promtail reached end of life on March 2, 2026. It is present only because P3 requires it, and the next logging-agent change must migrate this DaemonSet to Grafana Alloy.

## 5. sealed-secrets

Push commit 5, then verify:

```bash
kubectl -n argocd get application sealed-secrets
kubectl -n sealed-secrets rollout status deployment/sealed-secrets-controller --timeout=5m
kubectl get customresourcedefinition sealedsecrets.bitnami.com
```

Read [`sealed-secrets.md`](sealed-secrets.md) before the final Grafana step. Do not commit an unsealed Kubernetes Secret or a plaintext password.

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

## 7. Grafana ingress and sealed admin credentials

After commit 5 is live, create the real encrypted Grafana manifest by following [`sealed-secrets.md`](sealed-secrets.md). Save it as `argocd/apps/grafana-admin-sealedsecret.yaml`. Before pushing commit 7, add that encrypted file to the still-local final commit:

```bash
git add argocd/apps/grafana-admin-sealedsecret.yaml
git commit --amend --no-edit
git show --stat --oneline HEAD
git grep -nE 'admin-password:|stringData:|password:' -- ':!docs/sealed-secrets.md'
```

The grep must not reveal plaintext. Recompute commit 7's SHA after the amend, then push that SHA. This keeps the real SealedSecret and the Grafana switch atomic without adding an eighth app commit.

Verify:

```bash
kubectl -n monitoring get sealedsecret,grafana-admin-credentials
kubectl -n monitoring rollout status deployment/grafana --timeout=5m
kubectl -n monitoring get ingress,certificate,certificaterequest,challenge
kubectl -n monitoring wait certificate/grafana-tls --for=condition=Ready --timeout=10m
curl --insecure --head https://grafana.meshari.xyz/login
openssl s_client -connect grafana.meshari.xyz:443 -servername grafana.meshari.xyz </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

The generated Secret must contain only the `admin-user` and `admin-password` keys. Grafana must become Ready and its login page must load with the staging certificate.

## Promote staging certificates to production

Only after both staging certificates are Ready and both HTTPS routes work, change the issuer annotation in exactly these two files from `letsencrypt-staging` to `letsencrypt-prod`:

- `argocd/apps/demo.yaml`
- `argocd/apps/grafana-ingress.yaml`

Commit and push the promotion:

```bash
git add argocd/apps/demo.yaml argocd/apps/grafana-ingress.yaml
git commit -m "feat: promote public certificates to production"
git push origin main
kubectl -n demo wait certificate/demo-tls --for=condition=Ready --timeout=10m
kubectl -n monitoring wait certificate/grafana-tls --for=condition=Ready --timeout=10m
curl --fail --silent --show-error https://demo.meshari.xyz >/dev/null
curl --fail --silent --show-error https://grafana.meshari.xyz/login >/dev/null
```

If cert-manager does not replace an existing staging certificate after the issuer annotation changes, change each Ingress TLS `secretName` to a new `-prod-tls` name in the same promotion commit. Do not delete a Secret with kubectl.

## Rollback

During the staged rollout, stop immediately when a verification fails. Because no later app commit has been pushed yet, rollback is a normal Git revert of the remote tip:

```bash
git revert <FAILED_COMMIT_SHA>
git push origin main
kubectl -n argocd get application root-app --watch
```

Argo CD will reconcile the revert and prune resources owned by the reverted child Application. Never repair drift with `kubectl apply`, `kubectl edit`, or `kubectl delete`. For monitoring or Loki, inspect and preserve PVCs before reverting a previously healthy state; rollback of configuration is preferred to deleting stateful storage.

After the entire stack is live, revert dependent commits in reverse order (Grafana ingress, demo, sealed-secrets, logging, monitoring, cert-manager, ingress-nginx). Never remove cert-manager while TLS Ingresses still depend on it, and never remove ingress-nginx while HTTP-01 challenges or public routes remain.
