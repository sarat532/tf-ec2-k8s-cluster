output "master_public_ip" {
  description = "Public IP address of the Kubernetes master node."
  value       = aws_instance.ec2-k8s-master.public_ip
}

output "worker_public_ips" {
  description = "Public IP addresses of the Kubernetes worker nodes."
  value       = aws_instance.ec2-k8s-worker[*].public_ip
}

output "master_ssh_command" {
  description = "SSH command to connect to the Kubernetes master node."
  value       = "ssh -i ec2-k8s ec2-user@${aws_instance.ec2-k8s-master.public_ip}"
}
