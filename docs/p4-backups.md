# P4 live-node backup rollout

> **Execution status:** documented, not yet run. Every checkbox in this
> runbook remains an operator action. The repository change does not contact
> the live cluster or Cloudflare R2.

This procedure adds the P4 snapshot settings to the existing, stateful node
without reprovisioning it. K3s reads `/etc/rancher/k3s/config.yaml` in addition
to its service arguments; command-line arguments continue to take precedence.
The [K3s configuration-file documentation](https://docs.k3s.io/installation/configuration#configuration-file)
describes that behavior.

## Backup boundary

This backup protects the embedded-etcd datastore, including Kubernetes objects
and Secrets such as the Sealed Secrets controller key. It does **not** copy
application data stored in persistent volumes. In particular, Grafana's SQLite
database is on a node-local `local-path` volume and is not contained in an etcd
snapshot. K3s documents etcd snapshots as datastore backups and documents
`local-path` volumes as storage on the node; see [Backup and Restore](https://docs.k3s.io/datastore/backup-restore)
and [Volumes and Storage](https://docs.k3s.io/add-ons/storage). Do not replace
the live node on the strength of this backup alone.

The configured policy is:

- one scheduled snapshot each day at `03:00` in the node's system timezone;
- seven scheduled snapshots retained locally and in R2; and
- HTTPS uploads to an operator-selected private R2 bucket.

`etcd-snapshot-retention: 7` is a count, not a number of days. Because
`etcd-s3-retention` is not set separately, K3s applies the same value to S3.
On-demand snapshots have no automatic retention and remain until the operator
deletes or prunes them. These behaviors are documented in the
[K3s etcd-snapshot reference](https://docs.k3s.io/cli/etcd-snapshot).

## 1. Prepare R2

These steps happen in the Cloudflare dashboard and are not automated by this
repository:

1. Create a **private** R2 bucket. Choose its name locally; do not add the real
   name to this repository.
2. Create an R2 S3 API token with **Object Read & Write** access, restricted to
   that bucket. Restore requires read access as well as snapshot upload access.
3. Save the Access Key ID and Secret Access Key in a password manager. The
   secret cannot be displayed again after token creation.
4. Record the S3 endpoint shown by Cloudflare. For a default-jurisdiction
   bucket it has the form `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.
   K3s's endpoint value below uses only the host portion, without `https://`.
5. Keep the region as `auto`.

Cloudflare documents the bucket-scoped token flow and endpoint in its
[R2 S3 guide](https://developers.cloudflare.com/r2/get-started/s3/) and confirms
that the S3 region is `auto` in its
[S3 compatibility reference](https://developers.cloudflare.com/r2/api/s3/api/).
Use the dashboard-provided endpoint if the bucket has a jurisdiction-specific
endpoint.

Record the same values in the existing ignored Terraform variables file so a
future fresh cluster has its backup policy at birth. First verify that Git
ignores the file, then edit it locally; do **not** copy the example over an
existing file and do not run `terraform apply` against the live P3 node as part
of this rollout:

```bash
cd terraform
git check-ignore terraform.tfvars
${EDITOR:-vi} terraform.tfvars
```

Set the `etcd_snapshot_schedule_cron`, `etcd_snapshot_retention`,
`r2_endpoint`, `r2_bucket`, `r2_region`, `r2_access_key_id`, and
`r2_secret_access_key` entries using the operator-held values. Keep
`r2_endpoint` as a hostname without `https://`. The file remains local and
gitignored; Terraform state and EC2 user data will also contain these values if
the fresh-cluster configuration is ever applied, so both require secret-level
access controls.

## 2. Connect and record the baseline

From the local repository, use the private key matching the public key already
registered by Terraform:

```bash
cd terraform
cluster_ip="$(terraform output -raw elastic_ip)"
ssh -i /path/to/private-key "ubuntu@${cluster_ip}"
```

Run the remaining commands on the node. Confirm that the live service and node
are healthy before changing configuration:

```bash
sudo systemctl is-active k3s
sudo k3s --version
sudo k3s kubectl get nodes
sudo k3s kubectl get pods --all-namespaces
timedatectl status
```

The cron expression follows the node's displayed system timezone. Record the
exact K3s version and the rest of the baseline output in the operator's private
change log, not in Git; the version is an input to a future recovery-host
install.

## 3. Preserve and extend the live K3s configuration

The following procedure backs up an existing config file, refuses to create
duplicate P4 keys, prompts without echoing either R2 key, and sends the values
to a root-only file over standard input. The credentials do not appear in Git,
shell history, or process arguments. Do not enable shell tracing.

First, prepare the file and check that the backup keys are not already present:

```bash
bash
set -euo pipefail
set +x

k3s_config_file=/etc/rancher/k3s/config.yaml
k3s_config_backup="${k3s_config_file}.pre-p4.$(date -u +%Y%m%dT%H%M%SZ)"

sudo -v
sudo install -d -o root -g root -m 0755 /etc/rancher/k3s
if sudo test -e "$k3s_config_file"; then
  sudo cp --preserve=all "$k3s_config_file" "$k3s_config_backup"
  sudo chown root:root "$k3s_config_backup"
  sudo chmod 0600 "$k3s_config_backup"
  printf 'Existing configuration backed up to %s\n' "$k3s_config_backup"
else
  sudo install -o root -g root -m 0600 /dev/null "$k3s_config_file"
  printf 'No previous config.yaml existed; created a new root-only file.\n'
fi

if sudo grep -Eq '^[[:space:]]*(etcd-snapshot-schedule-cron|etcd-snapshot-retention|etcd-s3|etcd-s3-endpoint|etcd-s3-bucket|etcd-s3-region|etcd-s3-access-key|etcd-s3-secret-key):' "$k3s_config_file"; then
  printf 'Stop: an etcd snapshot or S3 key already exists. Update it once with sudoedit; do not append a duplicate.\n' >&2
  exit 1
fi
```

If the guard stops, run `sudoedit /etc/rancher/k3s/config.yaml`, preserve every
unrelated setting, and update the existing keys to match the block below. Do
not continue until every key occurs exactly once.

If the guard passes, run this in the same shell. Enter the endpoint **host**,
bucket, and keys from the password manager when prompted:

```bash
read -r -p 'R2 endpoint host (no https://): ' r2_endpoint_host
read -r -p 'R2 bucket: ' r2_bucket
read -r -s -p 'R2 access key ID: ' r2_access_key_id
printf '\n'
read -r -s -p 'R2 secret access key: ' r2_secret_access_key
printf '\n'
trap 'unset r2_endpoint_host r2_bucket r2_access_key_id r2_secret_access_key' EXIT

if [[ -z "$r2_endpoint_host" || -z "$r2_bucket" || -z "$r2_access_key_id" || -z "$r2_secret_access_key" ]]; then
  printf 'All R2 values are required. Nothing was written.\n' >&2
  exit 1
fi
if [[ "$r2_endpoint_host" == *://* || "$r2_endpoint_host" == *[[:space:]]* || "$r2_bucket" == *[[:space:]]* ]]; then
  printf 'Use an endpoint host without a URL scheme and a bucket without whitespace. Nothing was written.\n' >&2
  exit 1
fi

yaml_quote() {
  local yaml_value=$1
  yaml_value=${yaml_value//\\/\\\\}
  yaml_value=${yaml_value//\"/\\\"}
  printf '"%s"' "$yaml_value"
}

{
  printf '\n# P4: nightly embedded-etcd snapshots to private Cloudflare R2.\n'
  printf 'etcd-snapshot-schedule-cron: "0 3 * * *"\n'
  printf 'etcd-snapshot-retention: 7\n'
  printf 'etcd-s3: true\n'
  printf 'etcd-s3-endpoint: '
  yaml_quote "$r2_endpoint_host"
  printf '\n'
  printf 'etcd-s3-bucket: '
  yaml_quote "$r2_bucket"
  printf '\n'
  printf 'etcd-s3-region: "auto"\n'
  printf 'etcd-s3-access-key: '
  yaml_quote "$r2_access_key_id"
  printf '\n'
  printf 'etcd-s3-secret-key: '
  yaml_quote "$r2_secret_access_key"
  printf '\n'
} | sudo tee -a "$k3s_config_file" >/dev/null

sudo chown root:root "$k3s_config_file"
sudo chmod 0600 "$k3s_config_file"
unset r2_endpoint_host r2_bucket r2_access_key_id r2_secret_access_key
trap - EXIT
```

Verify permissions and key names without printing credential values:

```bash
sudo stat -c '%a %U:%G %n' /etc/rancher/k3s/config.yaml
sudo awk -F: '
  /^(etcd-snapshot-schedule-cron|etcd-snapshot-retention|etcd-s3|etcd-s3-endpoint|etcd-s3-bucket|etcd-s3-region|etcd-s3-access-key|etcd-s3-secret-key):/ {
    print $1 ": <configured>"
  }
' /etc/rancher/k3s/config.yaml
```

The mode must be `600`, ownership must be `root:root`, and all eight keys must
appear exactly once. Do not run `cat` on the file in a recorded terminal.

## 4. Restart K3s in the maintenance window

On this single-node cluster, restarting K3s briefly interrupts embedded etcd,
the Kubernetes API, and control-plane reconciliation. K3s deliberately leaves
the already-running containers running when its service stops, so workload pods
keep running during the restart; they cannot be scheduled or reconciled until
the service returns. This is not an availability guarantee, so verify both
public routes afterward. The distinction is documented in
[Stopping K3s](https://docs.k3s.io/upgrades/killall).

Do **not** run `k3s-killall.sh`; that script stops the containers and resets
containerd/networking state.

```bash
sudo systemctl restart k3s
sudo systemctl is-active k3s
sudo k3s kubectl wait node --all --for=condition=Ready --timeout=3m
sudo k3s kubectl get pods --all-namespaces
```

From a second terminal on the local workstation, verify the public paths while
the SSH session remains open:

```bash
curl --fail --silent --show-error https://demo.meshari.xyz >/dev/null
curl --fail --silent --show-error https://grafana.meshari.xyz/login >/dev/null
```

If the service is not active, inspect it without exposing the config file:

```bash
sudo systemctl status k3s --no-pager
sudo journalctl -u k3s -n 200 --no-pager
```

Use the timestamped pre-P4 file to restore the prior configuration if K3s
rejects the new one, then restart and recheck the baseline. If no config file
existed before P4, move the new file to a timestamped `.failed` filename rather
than deleting it, then restart. Do not proceed to a snapshot while K3s is
unhealthy.

## 5. Create and verify an on-demand R2 snapshot

With K3s healthy, trigger the acceptance snapshot using the root-only S3
settings from `config.yaml`:

```bash
sudo k3s etcd-snapshot save
sudo k3s etcd-snapshot list
sudo k3s kubectl get etcdsnapshotfile \
  -o custom-columns='NAME:.metadata.name,SNAPSHOT:.spec.snapshotName,NODE:.spec.nodeName,LOCATION:.spec.location,SIZE:.status.size,READY:.status.readyToUse'
```

Record the generated `on-demand-...` snapshot name. The list must show both a
local `file://...` entry and an `s3://...` entry for the same nonzero-sized
snapshot, and the S3 `ETCDSnapshotFile` must report `READY=true`. K3s documents
both list output and the `ETCDSnapshotFile` readiness record in its
[snapshot reference](https://docs.k3s.io/cli/etcd-snapshot).

Then verify independently in Cloudflare:

1. Open **Storage & databases → R2** in the Cloudflare dashboard.
2. Open the operator-selected bucket and its object browser.
3. Find the exact `on-demand-...` object reported by K3s.
4. Confirm its size is greater than zero and its upload time matches the test.

The on-demand acceptance object is not covered by scheduled retention. Keep it
until the restore exercise is complete, or remove it explicitly later through
the reviewed operational process.

## 6. Verify the first scheduled snapshot

After the next `03:00` in the node's system timezone, rerun:

```bash
sudo k3s etcd-snapshot list
sudo k3s kubectl get etcdsnapshotfile
```

Confirm that a new `etcd-snapshot-...` entry exists both locally and in R2,
then confirm the matching nonzero object in the R2 dashboard. After enough
nightly runs, confirm that only seven scheduled snapshots are retained.

## Recovery dependencies and completion record

An etcd snapshot is not independently restorable. K3s requires the original
server token at `/var/lib/rancher/k3s/server/token` to decrypt confidential
bootstrap data. Store that token in a separate, encrypted, off-node secret
store; never put it in this repository or a plaintext R2 object. This
requirement comes directly from the
[K3s backup warning](https://docs.k3s.io/datastore/backup-restore).

All R2 objects must remain private because a snapshot contains cluster state,
Kubernetes Secrets, and cluster CA key material. The K3s
[snapshot security notes](https://docs.k3s.io/cli/etcd-snapshot#security)
describe the snapshot and token sensitivity.

P4 backup rollout is complete only when the operator records all of these
outside the repository:

- [ ] R2 bucket exists and a bucket-scoped read/write token is stored safely.
- [ ] The existing ignored `terraform.tfvars` has the fresh-cluster R2 inputs;
      no Terraform apply was run against the live node for this rollout.
- [ ] Original K3s server token is backed up in an encrypted off-node store.
- [ ] Live `config.yaml` is root-owned, mode `0600`, and has the eight P4 keys.
- [ ] K3s restarted and returned Ready; workloads and both HTTPS routes passed.
- [ ] Manual snapshot appears locally, in K3s's S3 list, and in the R2 dashboard.
- [ ] First scheduled snapshot appears in R2 after `03:00` node time.
- [ ] Restore remains marked untested until the separate restore exercise is
      actually performed.
