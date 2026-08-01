data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_key_pair" "k3s" {
  key_name_prefix = "production-cluster-in-a-box-"
  public_key      = trimspace(file(pathexpand(var.ssh_public_key)))
}

resource "aws_instance" "k3s" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  key_name               = aws_key_pair.k3s.key_name

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    tls_san                     = aws_eip.k3s.public_ip
    etcd_snapshot_schedule_cron = var.etcd_snapshot_schedule_cron
    etcd_snapshot_retention     = var.etcd_snapshot_retention
    r2_endpoint                 = var.r2_endpoint
    r2_bucket                   = var.r2_bucket
    r2_region                   = var.r2_region
    r2_access_key_id            = var.r2_access_key_id
    r2_secret_access_key        = var.r2_secret_access_key
  })

  # P3 made this instance stateful: it now holds the cluster datastore,
  # Sealed Secrets key, and Grafana data. Cloud-init changes must never replace
  # it; live-node configuration is performed through the P4 backup runbook.
  user_data_replace_on_change = false

  root_block_device {
    delete_on_termination = true
    encrypted             = true
    volume_size           = 30
    volume_type           = "gp3"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
    http_tokens                 = "required"
  }

  depends_on = [
    aws_route.internet,
    aws_route_table_association.public,
    aws_vpc_security_group_egress_rule.all,
    aws_vpc_security_group_ingress_rule.http,
    aws_vpc_security_group_ingress_rule.https,
    aws_vpc_security_group_ingress_rule.ssh,
  ]

  tags = {
    Name = "production-cluster-in-a-box"
  }
}

resource "aws_eip" "k3s" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "production-cluster-in-a-box"
  }
}

resource "aws_eip_association" "k3s" {
  allocation_id = aws_eip.k3s.id
  instance_id   = aws_instance.k3s.id
}
