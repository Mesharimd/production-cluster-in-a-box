output "elastic_ip" {
  description = "Elastic IPv4 address assigned to the k3s server."
  value       = aws_eip.k3s.public_ip
}

output "kubeconfig_scp_command" {
  description = "Command that copies the k3s kubeconfig to the current directory."
  value       = "scp -i ${trimsuffix(pathexpand(var.ssh_public_key), ".pub")} ubuntu@${aws_eip.k3s.public_ip}:/etc/rancher/k3s/k3s.yaml ./kubeconfig"
}
