output "bastion_public_ip" {
  value       = aws_instance.bastion_host.public_ip
  description = "The public IP address of bastion host instance"
}

output "alb_dns" {
  value = aws_lb.alb.dns_name
}

output "nlb_dns" {
  value = aws_lb.nlb.dns_name
}

output "db_endpoint" {
  value = aws_db_instance.mysql_instance.endpoint
}