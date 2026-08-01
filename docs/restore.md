# Restore embedded etcd from Cloudflare R2

> **UNTESTED DISASTER-RECOVERY PROCEDURE**
>
> Every restore step in this document is documented but has not been executed
> against this cluster. A restore stops the control plane, rewinds Kubernetes
> state, and can make the live cluster unusable if the wrong snapshot or server
> token is selected. Do not use the only live node as a rehearsal target. Test
> this procedure on an isolated recovery node before calling P4 restore-tested.

This runbook covers the repository's single-server K3s cluster with embedded
etcd and snapshots stored in a private Cloudflare R2 bucket. It follows the
official [K3s embedded-etcd restore procedure](https://docs.k3s.io/cli/etcd-snapshot#restoring-snapshots)
and distinguishes restoring the existing node from restoring onto a fresh host.

## What this backup can and cannot recover

An etcd snapshot contains the Kubernetes datastore, including Kubernetes
Secrets and the Sealed Secrets controller's private-key Secret. K3s also records
cluster CA material in the snapshot. The snapshot is protected by a key derived
from the original server token, which is why the original
`/var/lib/rancher/k3s/server/token` is mandatory for recovery. See the official
[K3s backup warning](https://docs.k3s.io/datastore/backup-restore) and
[snapshot security notes](https://docs.k3s.io/cli/etcd-snapshot#security).

The snapshot does **not** contain:

- the EC2 instance, Elastic IP, security group, or Terraform state;
- `/etc/rancher/k3s/config.yaml` or the original server-token file;
- the bytes stored in local-path PersistentVolumes.

Grafana's SQLite database is stored on its `local-path` PVC, not in etcd. K3s
describes local-path claims as storage on the node in its
[storage documentation](https://docs.k3s.io/add-ons/storage). A same-node etcd
restore can continue to use the existing Grafana volume only if the underlying
disk and local-path directory remain intact. An R2 etcd snapshot alone cannot
restore the Grafana database onto a fresh disk. P4 does not yet provide a
separate volume backup; stop and recover the volume from an independently
protected disk backup before claiming fresh-host Grafana recovery.

Sealed Secrets has a different boundary: its controller key is a Kubernetes
Secret and therefore is part of the etcd snapshot. Restoring that key is what
allows the existing encrypted Grafana credential in Git to decrypt again. If
the R2 snapshot and original server token are both lost, this backup chain
cannot recover that key.

## Status matrix

| Recovery action | Status |
| --- | --- |
| Select and download an R2 snapshot through K3s | Documented, **not tested** |
| Restore the existing single server | Documented, **not tested** |
| Restore onto a fresh server with the original token | Documented, **not tested** |
| Recover the Sealed Secrets private key through etcd | Documented, **not tested** |
| Recover Grafana PVC data on the same intact disk | Verification documented, **not tested** |
| Recover Grafana PVC data onto a fresh disk | **Not provided by P4** |

## Prepare recovery material before an incident

### Back up the original server token off-node

The token is not replaceable during restore. K3s uses it to decrypt confidential
bootstrap data in the snapshot; a new token makes the snapshot unusable. Store
an encrypted off-node copy now, separate from both the EC2 disk and this Git
repository.

From the trusted operator workstation, set paths outside this repository and
copy the token without printing it to the terminal:

```bash
export CLUSTER_HOST="ubuntu@REPLACE_WITH_ELASTIC_IP"
export TOKEN_BACKUP_PATH="/absolute/encrypted/off-node/path/k3s-server-token"
umask 077
ssh "$CLUSTER_HOST" 'sudo cat /var/lib/rancher/k3s/server/token' \
  > "$TOKEN_BACKUP_PATH"
chmod 0600 "$TOKEN_BACKUP_PATH"
test -s "$TOKEN_BACKUP_PATH"
unset CLUSTER_HOST TOKEN_BACKUP_PATH
```

Do not run `cat` against the local copy, paste the value into shell history, or
place it in the repository. Move it into an encrypted password manager or
offline recovery vault with tightly controlled access. Store the R2 access-key
ID and secret access key in the same class of secure off-node system, preferably
as a separately controlled record.

### Keep R2 private and credentials scoped

The live server needs credentials that can write scheduled snapshots and read
them during recovery. Cloudflare recommends an Object Read & Write token scoped
to the specific bucket; the secret is displayed only when the token is created.
See [Cloudflare R2 authentication](https://developers.cloudflare.com/r2/api/tokens/).

Cloudflare's S3 endpoint is
`https://<ACCOUNT_ID>.r2.cloudflarestorage.com`, and R2's S3 region is `auto`.
These are documented in Cloudflare's
[S3 compatibility reference](https://developers.cloudflare.com/r2/api/s3/api/).
The K3s `etcd-s3-endpoint` value uses the endpoint hostname without the
`https://` prefix; HTTPS remains enabled because `etcd-s3-insecure` is not set.

Treat the snapshot and server token together as cluster-root credentials. K3s
warns that possession of both can expose encrypted resources and cluster CA
private keys. Accept only snapshots whose identity and chain of custody the
operator has verified.

## Safety stop before any restore

Do not continue until all of these statements are true:

1. An incident owner has approved destructive recovery and the maintenance
   window. This is not a routine restart.
2. The exact R2 object and its timestamp are known. For an S3 restore, K3s needs
   the snapshot **filename**, not an `s3://` URL or local path.
3. The original server token has been recovered from the secure off-node copy.
4. The target has a working K3s binary and service unit installed in a stopped
   state. Prefer the exact K3s version that created the snapshot; K3s documents
   that a higher minor version is acceptable, but same-version recovery removes
   an avoidable variable. The repository's ordinary fresh-cluster cloud-init
   starts K3s immediately and is therefore **not** a tested recovery-host
   provisioner.
5. The target node has outbound HTTPS access to the private R2 bucket and the
   operator has the endpoint hostname, bucket name, region `auto`, access-key
   ID, and secret access key.
6. For same-node recovery, the existing server token and local-path volume data
   are still present. For fresh-node recovery, any required Grafana volume data
   has a separate recovery source.
7. A failed original node has been fenced before a fresh restored node becomes
   active. Never run the original and restored single-server clusters
   concurrently under the same Elastic IP, DNS names, or cluster identity.

If any item is false or uncertain, stop. Do not run `--cluster-reset`.

## Select the R2 snapshot

On a node that already has the root-only R2 configuration, list snapshots
without putting credentials on the command line:

```bash
sudo k3s etcd-snapshot list
```

Choose a row whose location begins with `s3://` and record its exact snapshot
filename, size, and creation time in the incident record. Independently open
the Cloudflare dashboard, select **R2 object storage**, open the operator-created
bucket, and confirm the same object exists. Cloudflare documents R2 bucket and
credential management in its [S3 getting-started guide](https://developers.cloudflare.com/r2/get-started/s3/).

Do not restore an object merely because its name looks plausible. Confirm the
timestamp is before the incident but recent enough for the accepted recovery
point objective.

## Root-only R2 configuration

K3s must be able to read R2 before the Kubernetes API server exists. A
Kubernetes S3 configuration Secret cannot help during restore because the API
server is unavailable; K3s explicitly documents this limitation under
[S3 configuration Secret support](https://docs.k3s.io/cli/etcd-snapshot#s3-configuration-secret-support).

Therefore, put the R2 settings directly in `/etc/rancher/k3s/config.yaml` on the
target node. Enter values interactively on that node, never in Git, Terraform
examples, chat, command-line arguments, or shell history.

The required block is:

```yaml
etcd-snapshot-schedule-cron: "0 3 * * *"
etcd-snapshot-retention: 7
etcd-s3: true
etcd-s3-endpoint: "<ACCOUNT_ID>.r2.cloudflarestorage.com"
etcd-s3-bucket: "<R2_BUCKET_NAME>"
etcd-s3-region: "auto"
etcd-s3-access-key: "<R2_ACCESS_KEY_ID>"
etcd-s3-secret-key: "<R2_SECRET_ACCESS_KEY>"
```

Replace every placeholder only inside the target node's root-owned file. Do not
commit the rendered file.

For the existing node, the P4 live-node runbook should already have installed
this block. Confirm only ownership, mode, and required key names; do not print
the values:

```bash
sudo stat -c '%U:%G %a %n' /etc/rancher/k3s/config.yaml
sudo awk -F: '
  /^(etcd-snapshot-schedule-cron|etcd-snapshot-retention|etcd-s3|etcd-s3-endpoint|etcd-s3-bucket|etcd-s3-region|etcd-s3-access-key|etcd-s3-secret-key):/ {
    print $1
  }
' /etc/rancher/k3s/config.yaml
```

The file must be owned by `root:root`, mode `600`, and show every listed key.

For a fresh target, install the same K3s version without enabling or starting
the service. Replace the two non-secret placeholders with the version recorded
by the backup runbook and the Elastic IP that must remain in the API server
certificate:

```bash
sudo -v
set -o pipefail
curl -sfL https://get.k3s.io | \
  sudo env \
    INSTALL_K3S_VERSION="<ORIGINAL_K3S_VERSION>" \
    INSTALL_K3S_SKIP_START=true \
    INSTALL_K3S_SKIP_ENABLE=true \
    /bin/sh -s - server \
    --cluster-init \
    --disable traefik \
    --tls-san "<ELASTIC_IP>" \
    --write-kubeconfig-mode 0640 \
    --write-kubeconfig-group ubuntu

sudo systemctl show k3s \
  --property=ActiveState \
  --property=UnitFileState
```

The required result is `ActiveState=inactive` and `UnitFileState=disabled`.
`INSTALL_K3S_SKIP_START` and `INSTALL_K3S_SKIP_ENABLE` are the official K3s
installer controls for creating a service without its first start; see the
[install-script environment reference](https://docs.k3s.io/reference/env-variables).
If either state differs, stop and fence the target before continuing.

Now create and edit the file without putting values in process arguments:

```bash
sudo install -d -o root -g root -m 0700 /etc/rancher/k3s
sudo test ! -e /etc/rancher/k3s/config.yaml
sudo install -o root -g root -m 0600 /dev/null /etc/rancher/k3s/config.yaml
sudo vi /etc/rancher/k3s/config.yaml
sudo chown root:root /etc/rancher/k3s/config.yaml
sudo chmod 0600 /etc/rancher/k3s/config.yaml
sudo stat -c '%U:%G %a %n' /etc/rancher/k3s/config.yaml
```

The installer command persists the same server arguments used by
`terraform/cloud-init.yaml.tftpl`; the root-only file supplies the R2 settings.
Add this line to that file using the value from the original
`/var/lib/rancher/k3s/server/token` backup:

```yaml
token: "<ORIGINAL_SERVER_TOKEN>"
```

Entering `token` in the root-only file is the safer equivalent of passing
`--token` on the command line. Do not allow a fresh K3s start to generate and
persist a replacement token before the restore.

## Path A: restore the existing node

> **Status: documented, not tested. Expect control-plane and application
> disruption.**

This path assumes the original EC2 root disk, K3s data directory, token file,
and local-path volumes are intact, but Kubernetes state must be rewound.

1. Reconfirm the token and configuration exist without printing their contents:

   ```bash
   sudo test -s /var/lib/rancher/k3s/server/token
   sudo test -s /etc/rancher/k3s/config.yaml
   sudo stat -c '%U:%G %a %n' \
     /var/lib/rancher/k3s/server/token \
     /etc/rancher/k3s/config.yaml
   ```

2. Stop K3s:

   ```bash
   sudo systemctl stop k3s
   sudo systemctl is-active k3s
   ```

   `is-active` must report `inactive`. Treat the cluster as unavailable from
   this point.

3. Restore the exact S3 snapshot. Because the R2 settings are in
   `/etc/rancher/k3s/config.yaml`, pass only the snapshot filename:

   ```bash
   sudo k3s server \
     --cluster-reset \
     --cluster-reset-restore-path="<SNAPSHOT_FILENAME>"
   ```

4. Wait for the command to return successfully and print this exact K3s
   completion message:

   ```text
   Managed etcd cluster membership has been reset, restart without --cluster-reset flag now.
   ```

   Do not start K3s unless that message appeared. During restore, K3s downloads
   the S3 object, verifies it, moves the current etcd database to an
   `etcd-old-<timestamp>` directory, restores the snapshot, and resets membership
   to the current single server.

5. Start K3s normally, without either reset flag:

   ```bash
   sudo systemctl start k3s
   sudo systemctl is-active k3s
   sudo journalctl -u k3s --since '-10 minutes' --no-pager
   ```

   The service must report `active` and the log must not contain continuing
   datastore, certificate, or S3 errors.

## Path B: restore onto a fresh node

> **Status: documented, not tested. This is disaster recovery, not permission
> to replace the healthy P3 node.**

Use this path only when the original node cannot be recovered. The target must
have the reviewed K3s binary and systemd unit installed, but K3s must remain
stopped until its configuration contains both the R2 settings and the original
server token. Do not use `terraform apply` on the live stack to create or
rehearse this target: P4 does not automate replacement-node provisioning, and
the healthy P3 node must never be replaced.

1. Fence the original node. Confirm it cannot rejoin, serve the Elastic IP, or
   accept application writes.
2. Recover the original server-token value from the encrypted off-node backup.
   A token generated by the fresh host will not work.
3. Build `/etc/rancher/k3s/config.yaml` using the root-only procedure above.
   Include the same R2 endpoint hostname, bucket, region `auto`, access-key ID,
   secret access key, and the original `token` value. Keep the file at
   `root:root` mode `600`; the stopped installer has already persisted the
   remaining server arguments in the service definition.
4. Confirm K3s remains stopped:

   ```bash
   sudo systemctl stop k3s
   sudo systemctl is-active k3s
   ```

5. Run the same filename-only restore command:

   ```bash
   sudo k3s server \
     --cluster-reset \
     --cluster-reset-restore-path="<SNAPSHOT_FILENAME>"
   ```

6. Do not continue until the command exits successfully with the exact reset
   completion message shown in Path A. Then enable and start K3s normally:

   ```bash
   sudo systemctl enable k3s
   sudo systemctl start k3s
   sudo systemctl is-active k3s
   sudo journalctl -u k3s --since '-10 minutes' --no-pager
   sudo test -s /var/lib/rancher/k3s/server/token
   ```

K3s documents fresh-host recovery under
[Restoring to new hosts](https://docs.k3s.io/cli/etcd-snapshot#restoring-to-new-hosts).
The restored snapshot still contains the old Node resource. If the new host has
a different node name, leave the stale object alone until the new node is Ready
and workloads have been verified. Only then identify and delete the confirmed
old node:

```bash
sudo k3s kubectl get nodes -o wide
OLD_NODE_NAME="REPLACE_WITH_CONFIRMED_OLD_NODE_NAME"
sudo k3s kubectl delete node "$OLD_NODE_NAME"
unset OLD_NODE_NAME
```

Never delete the only Ready node, and never run the delete command when the old
and new identities are ambiguous.

## Post-restore verification

Run every check before declaring recovery complete.

### Control plane and GitOps

```bash
sudo k3s kubectl wait node --all --for=condition=Ready --timeout=5m
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
sudo k3s kubectl -n argocd get applications
```

All expected Argo CD Applications must return to `Synced` and `Healthy`. Argo
CD may reconcile the restored point-in-time state forward to the current Git
`main`; record any resulting changes in the incident timeline.

### Sealed Secrets recovery chain

```bash
sudo k3s kubectl -n sealed-secrets get deployment sealed-secrets-controller
sudo k3s kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o name
sudo k3s kubectl -n monitoring get sealedsecret grafana-admin-credentials
sudo k3s kubectl -n monitoring get secret grafana-admin-credentials
```

The controller must be Ready, at least one sealing-key Secret must be listed,
and the Grafana Secret must be regenerated from the existing SealedSecret. Do
not display either Secret's data. If the key is absent or the SealedSecret
cannot decrypt, stop: the recovery chain has not succeeded.

### Stateful storage and Grafana

```bash
sudo k3s kubectl -n monitoring get pvc grafana
sudo k3s kubectl -n monitoring get pods -o wide
sudo k3s kubectl -n logging get pvc,pods
```

The Grafana and Loki claims must be `Bound`, and their workloads must be Ready.
For a same-node restore, log into Grafana and confirm the expected dashboards,
datasources, and persisted settings—not merely that the login page opens. On a
fresh disk, a Bound replacement PVC is **not** proof that the original database
was recovered; compare against the separate volume-recovery record.

### Ingress, certificates, and routes

```bash
sudo k3s kubectl get ingress,certificate -A
curl --head https://demo.meshari.xyz
curl --head https://grafana.meshari.xyz
```

Both routes must complete TLS successfully with the production certificates.

### Snapshot chain

```bash
sudo k3s etcd-snapshot list
```

Confirm the restored snapshot appears with an `s3://` location and that K3s can
still query R2 using the root-only configuration. After the cluster is stable,
follow the backup runbook to create and independently verify a new manual
post-recovery snapshot.

## Abort and rollback guidance

- If the restore command reports an R2 authentication, download, checksum, token,
  or datastore error, leave K3s stopped. Preserve the complete command output
  and current `/var/lib/rancher/k3s/server/db` directory for investigation.
- If the exact reset-complete message did not appear, do not start K3s and do not
  rerun `--cluster-reset` with guessed values.
- K3s creates `/var/lib/rancher/k3s/server/db/reset-flag` to prevent accidental
  repeated resets and moves the previous database to an
  `etcd-old-<timestamp>` directory. Do not delete the flag, the old database, or
  any local-path volume as an improvised repair. A normal successful K3s start
  clears the reset flag.
- If the cluster starts but the selected recovery point is wrong, stop
  application writes, preserve evidence, and obtain a new incident approval
  before attempting a different known-good snapshot. Do not improvise a manual
  database swap.
- On a fresh-host attempt, keep the original node fenced throughout. If recovery
  is abandoned, stop the fresh K3s service before changing networking or
  returning traffic to any surviving original node.

A restore is considered successful only after every post-restore check passes,
the sealed credential decrypts, stateful data is accounted for, and a new R2
snapshot has been independently observed. Until an isolated rehearsal proves
that sequence, README and project status must continue to say **restore
documented, not tested**.
