output "bastion_public_ip" {
  value       = aws_instance.bastion_host.public_ip
  description = "The public IP address of bastion host instance"
}