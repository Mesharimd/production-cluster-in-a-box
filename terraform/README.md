# AWS infrastructure

This P1 Terraform stack creates one isolated AWS environment for a single-node
k3s cluster:

- a dedicated VPC and public subnet;
- an internet gateway and public route;
- a security group allowing inbound TCP 22, 80, and 443 only;
- one `c7i-flex.large` EC2 instance using the latest Canonical Ubuntu 24.04 amd64 AMI;
- a 30 GB encrypted gp3 root volume; and
- an Elastic IP that survives instance stops and starts.

Cloud-init installs k3s in embedded-etcd mode with Traefik disabled. The
kubeconfig remains at `/etc/rancher/k3s/k3s.yaml` and is readable by the Ubuntu
user's group so the Terraform output can provide a working `scp` command.

This stack creates new, isolated resources. It does not import, reference, or
modify any existing infrastructure.

## Prerequisites

- Terraform 1.5 or newer
- AWS CLI with an IAM-user profile already configured
- an existing local SSH key pair

Copy the example variables file, then replace every placeholder with local
values:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
${EDITOR:-vi} terraform.tfvars
```

`terraform.tfvars` is gitignored. Set `ssh_ingress_cidr` to your current public
IPv4 address with a `/32` suffix whenever possible. Its variable default is
`0.0.0.0/0` for initial accessibility, which permits SSH attempts from the
internet and is less secure.

The SSH public-key path should end in `.pub`, with its matching private key at
the same path without that suffix. Terraform reads only the public key; the
private key is never read or uploaded. This filename convention lets the
`kubeconfig_scp_command` output include the correct identity file.

Confirm the selected profile before provisioning:

```bash
aws sts get-caller-identity --profile YOUR_PROFILE --region YOUR_REGION
```

## Provision

Run these commands from this directory:

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

Terraform prints the Elastic IP and a ready-to-paste kubeconfig copy command.
Wait for cloud-init, then verify the node over SSH:

```bash
ssh -i /path/to/your-key ubuntu@ELASTIC_IP
sudo cloud-init status --wait
sudo k3s kubectl get nodes
exit
terraform output -raw kubeconfig_scp_command
```

Run the printed `scp` command from this directory. Destroy the isolated stack
when it is no longer needed:

```bash
terraform destroy
```

## Cost and provider status

The stack is intended to run on AWS new-account credits. At the project plan's
estimate, a `c7i-flex.large` consumes about USD 30 per month of credit; the 30 GB gp3
volume and public IPv4 address also have charges. Check the current
[EC2 On-Demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/),
[EBS pricing](https://aws.amazon.com/ebs/pricing/), and
[public IPv4 pricing](https://aws.amazon.com/vpc/pricing/) for the selected
region, and set a Billing budget before leaving the stack running.

The OCI Always Free variant is parked because account signup was blocked. A
roadmap issue tracks it as a future provider option. The higher-level cluster
configuration is deliberately provider-portable so the workload can later move
to OCI or another VPS after AWS credits expire.

## Free-plan account notes (learned in production, 2026-07-29)

- New AWS "free plan" accounts may only launch free-tier-eligible instance
  types (`aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`).
  `c7i-flex.large` (2 vCPU / 4 GB) is eligible and is this repo's default.
- AWS provider v6.x intermittently produced `InvalidHttpRequest: Unable to
  parse request` errors on EC2 calls in this environment; the provider is
  pinned to `~> 5.0`, which is stable.
