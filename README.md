# production-cluster-in-a-box

> One command from an empty cloud account to a production-grade Kubernetes
> cluster — GitOps-managed, TLS-secured, fully observable, with automated,
> tested backups. Runs on AWS free-plan credits; provider-portable by design.

<!-- demo GIF goes here (P5) -->

> **Status:** Terraform → k3s on AWS ✅ · ArgoCD GitOps loop live ✅ ·
> ingress/TLS/observability, R2 backups, and CI in progress — follow the
> [Issues](../../issues).

## Architecture

```mermaid
flowchart LR
    TF[Terraform] -->|provisions| VM[AWS EC2 VM<br/>cloud-init installs k3s]
    VM --> ARGO[ArgoCD]
    ARGO -->|app-of-apps| APPS
    subgraph APPS[GitOps-managed apps]
      ING[ingress-nginx]
      CERT[cert-manager + Let's Encrypt]
      MON[Prometheus + Grafana]
      LOKI[Loki + Promtail]
      SEAL[sealed-secrets]
      DEMO[demo app]
    end
    VM -->|etcd snapshots, nightly| R2[(Cloudflare R2)]
```

Everything after the VM exists only as YAML in this repo. ArgoCD watches
`argocd/apps/` — merging a manifest to main **is** the deployment.

## Quickstart

```bash
git clone https://github.com/Mesharimd/production-cluster-in-a-box
cd production-cluster-in-a-box/terraform
cp terraform.tfvars.example terraform.tfvars   # set your AWS profile + SSH key
terraform apply                                 # ~5 min: VM + network + k3s
cd .. && ./scripts/bootstrap.sh                 # kubeconfig + ArgoCD + root app
```

~10 minutes later: Grafana, Loki, TLS ingress, and a demo app — all live,
all declarative, all reconciled by ArgoCD.

## What's included

| Component | Why |
|---|---|
| **k3s** (single node, embedded etcd) | Production-certified K8s in one binary, right-sized for one VM |
| **ArgoCD app-of-apps** | One root Application installs everything; `prune` + `selfHeal` on |
| **ingress-nginx + cert-manager** | Real TLS via Let's Encrypt on real subdomains |
| **kube-prometheus-stack + Loki** | Metrics, dashboards, and logs in one Grafana |
| **sealed-secrets** | Secrets live in git safely; nothing sensitive in plaintext |
| **etcd → R2 snapshots** | Nightly cluster-state backups, S3-compatible, restore documented |

## Design decisions

- **Why k3s over kubeadm:** single binary, CNCF-certified, embedded etcd
  enables built-in S3 snapshots — full production semantics without
  multi-node cost.
- **Why app-of-apps:** the cluster's entire state is this repo. Rebuild =
  `terraform apply` + bootstrap; drift is auto-healed.
- **Why AWS `c7i-flex.large`:** free-plan-eligible (2 vCPU / 4 GB), runs the
  full stack on new-account credits — and AWS is the provider this cluster's
  audience actually runs. The design is provider-portable: an OCI Always Free
  variant is on the roadmap, and moving is `terraform apply` + bootstrap.

## Backups & restore

Nightly etcd snapshots ship to Cloudflare R2 via k3s's native S3 support.
Restore procedure will be documented in [docs/restore.md](docs/restore.md) and
tested before this section loses the word "will".

## Teardown

```bash
terraform destroy   # removes everything; R2 bucket cleanup noted in docs
```

## Roadmap

See [Issues](../../issues) — Velero, multi-node, Istio mTLS, external-dns.

## License

MIT
