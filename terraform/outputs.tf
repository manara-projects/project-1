output "bastion_public_ip" {
  value       = aws_instance.bastion_host.public_ip
  description = "Public IP of the Bastion Host"
}

output "alb_dns_name" {
  value       = aws_lb.alb.dns_name
  description = "DNS name of the ALB"
}

output "nlb_dns_name" {
  value       = aws_lb.nlb.dns_name
  description = "DNS name of the NLB"
}

output "rds_endpoint" {
  value       = aws_db_instance.mysql_instance.endpoint
  description = "Endpoint to connect to the MySQL database"
}

output "cloudfront_domain_name" {
  value       = aws_cloudfront_distribution.cloudfront_alb.domain_name
  description = "CloudFront distribution domain"
}

output "s3_logs_bucket" {
  value       = aws_s3_bucket.logs_bucket.bucket
  description = "S3 bucket name used for logging"
}

output "route53_zone_id" {
  value       = aws_route53_zone.application_zone.zone_id
  description = "Route53 Hosted Zone ID for the domain"
}