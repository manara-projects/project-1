provider "aws" {
  region = var.region
}

locals {
  common_tags = {
    Terraform   = "true"
    Managed_by  = "terraform"
    Environment = var.env
  }

  assignment_list = [0, 1, 0, 1, 0, 1]
}

data "aws_availability_zones" "az" {
  state = "available"
}

################################### NETWORK ################################### 

resource "aws_vpc" "vpc" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "VPC"
  })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = merge(local.common_tags, {
    Name = "igw"
  })
}

resource "aws_eip" "eip" {
  tags = merge(local.common_tags, {
    Name = "elastic_ip"
  })
}

resource "aws_subnet" "public_subnets" {
  count                   = 2
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = cidrsubnet(var.cidr, 8, count.index + 1)
  map_public_ip_on_launch = true
  availability_zone       = element(data.aws_availability_zones.az.names, count.index)

  tags = merge(local.common_tags, {
    Name = "public_subnet_${count.index + 1}"
  })
}

resource "aws_subnet" "private_subnets" {
  count                   = 6
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = cidrsubnet(var.cidr, 8, count.index + 101)
  map_public_ip_on_launch = false
  availability_zone       = element(data.aws_availability_zones.az.names, local.assignment_list[count.index])

  tags = merge(local.common_tags, {
    Name = "private_subnet_${count.index + 1}"
  })
}

resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.eip.id
  subnet_id     = aws_subnet.public_subnets[0].id

  tags = merge(local.common_tags, {
    Name = "nat_gateway"
  })

  depends_on = [
    aws_subnet.public_subnets[0],
    aws_eip.eip
  ]
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  route {
    cidr_block = var.cidr
    gateway_id = "local"
  }

  tags = merge(local.common_tags, {
    Name = "public_route_table"
  })

  depends_on = [
    aws_eip.eip
  ]
}
resource "aws_route_table_association" "public_rt_association" {
  for_each       = { for i, s in aws_subnet.public_subnets : "subnet-${i + 1}" => s.id }
  subnet_id      = each.value
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.nat_gateway.id
  }

  route {
    cidr_block = var.cidr
    gateway_id = "local"
  }

  tags = merge(local.common_tags, {
    Name = "private_route_table"
  })

  depends_on = [
    aws_nat_gateway.nat_gateway
  ]
}
resource "aws_route_table_association" "private_rt_association" {
  for_each       = { for i, s in aws_subnet.private_subnets : "subnet-${i + 1}" => s.id }
  subnet_id      = each.value
  route_table_id = aws_route_table.private_rt.id
}

################################### Bastion Host ###################################

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "name"
    values = ["al2023-ami-2023*"]
  }
}

resource "aws_instance" "bastion_host" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.bastion_instance_type
  associate_public_ip_address = true
  key_name                    = aws_key_pair.key-pair.key_name
  subnet_id                   = aws_subnet.public_subnets[1].id
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]

  tags = merge(local.common_tags, {
    Name = "bastion_host"
  })
}

resource "aws_key_pair" "key-pair" {
  key_name   = "bastion_key"
  public_key = file(var.public_key)
}

resource "aws_security_group" "bastion_sg" {
  name        = "bastion_security_group"
  description = "Allow TLS inbound traffic and all outbound traffic"
  vpc_id      = aws_vpc.vpc.id

  tags = merge(local.common_tags, {
    Name = "bastion_security_group"
  })
}

resource "aws_vpc_security_group_ingress_rule" "bastion_allow_ssh" {
  security_group_id = aws_security_group.bastion_sg.id
  cidr_ipv4         = var.my_public_ip
  from_port         = 22
  ip_protocol       = "tcp"
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "bastion_allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.bastion_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}

################################### AUTOSCALING GROUP ###################################

resource "aws_launch_template" "frontend_template" {
  name                   = "frontend_launch_template"
  description            = "the frontend template for auto scaling group 1"
  image_id               = data.aws_ami.amazon_linux.id
  instance_type          = var.frontend_instance_type
  key_name               = aws_key_pair.key-pair.key_name
  vpc_security_group_ids = [aws_security_group.frontend_sg.id]
  user_data              = file(var.frontend_script)
  network_interfaces {
    associate_public_ip_address = false
  }

  tags = merge(local.common_tags, {
    Name = "frontend_launch_template"
  })
}

resource "aws_autoscaling_group" "frontend_asg" {
  name                = "autoscaling_group_1"
  vpc_zone_identifier = [for i in aws_subnet.public_subnets : i.id]
  max_size            = 4
  min_size            = 1
  desired_capacity    = 2
  target_group_arns   = [aws_autoscaling_group.backend_asg.arn]
  launch_template {
    id      = aws_launch_template.frontend_template.id
    version = "$Latest"
  }
}

resource "aws_launch_template" "backend_template" {
  name                   = "backend_launch_template"
  description            = "the backend template for auto scaling group 1"
  image_id               = data.aws_ami.amazon_linux.id
  instance_type          = var.backend_instance_type
  key_name               = aws_key_pair.key-pair.key_name
  vpc_security_group_ids = [aws_security_group.backend_sg.id]
  user_data              = file(var.backend_script)
  network_interfaces {
    associate_public_ip_address = false
  }

  tags = merge(local.common_tags, {
    Name = "backend_launch_template"
  })
}

resource "aws_autoscaling_group" "backend_asg" {
  name                = "autoscaling_group_2"
  vpc_zone_identifier = [for i in aws_subnet.private_subnets : i.id]
  max_size            = 4
  min_size            = 1
  desired_capacity    = 2
  target_group_arns   = [aws_lb_target_group.backend_tg.arn]
  launch_template {
    id      = aws_launch_template.backend_template.id
    version = "$Latest"
  }
}

resource "aws_security_group" "frontend_sg" {
  name        = "frontend_security_group"
  description = "Allow TLS inbound traffic and all outbound traffic"
  vpc_id      = aws_vpc.vpc.id

  tags = merge(local.common_tags, {
    Name = "frontend_security_group"
  })
}

resource "aws_vpc_security_group_ingress_rule" "frontend_allow_ssh" {
  security_group_id            = aws_security_group.frontend_sg.id
  referenced_security_group_id = aws_security_group.bastion_sg.id
  from_port                    = 22
  ip_protocol                  = "tcp"
  to_port                      = 22
}

resource "aws_vpc_security_group_ingress_rule" "frontend_allow_http" {
  security_group_id            = aws_security_group.frontend_sg.id
  referenced_security_group_id = aws_security_group.alb_sg.id
  from_port                    = 80
  ip_protocol                  = "tcp"
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "frontend_allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.frontend_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}

resource "aws_security_group" "backend_sg" {
  name        = "backend_security_group"
  description = "Allow TLS inbound traffic and all outbound traffic"
  vpc_id      = aws_vpc.vpc.id

  tags = merge(local.common_tags, {
    Name = "backend_security_group"
  })
}

resource "aws_vpc_security_group_ingress_rule" "backend_allow_ssh" {
  security_group_id            = aws_security_group.backend_sg.id
  referenced_security_group_id = aws_security_group.bastion_sg.id
  from_port                    = 22
  ip_protocol                  = "tcp"
  to_port                      = 22
}

resource "aws_vpc_security_group_ingress_rule" "backend_allow_http_1" {
  security_group_id = aws_security_group.backend_sg.id
  cidr_ipv4         = aws_subnet.private_subnets[2].cidr_block
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "backend_allow_http_2" {
  security_group_id = aws_security_group.backend_sg.id
  cidr_ipv4         = aws_subnet.private_subnets[3].cidr_block
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "backend_allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.backend_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}

################################### ELASTIC LOADBALANCER ###################################

resource "aws_lb_target_group" "frontend_tg" {
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.vpc.id
}

resource "aws_lb" "alb" {
  name                       = "alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb_sg.id]
  subnets                    = [for i in aws_subnet.public_subnets : i.id]
  enable_deletion_protection = false

  tags = merge(local.common_tags, {
    Name = "alb"
  })
}

resource "aws_lb_listener" "frontend_lb_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_tg.arn
  }
}

resource "aws_lb_listener_rule" "alb_rule_1" {
  listener_arn = aws_lb_listener.frontend_lb_listener.arn
  priority     = 99

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_tg.arn
  }

  condition {
    path_pattern {
      values = ["/"]
    }
  }
}

resource "aws_security_group" "alb_sg" {
  name        = "alb_security_group"
  description = "Allow TLS inbound traffic and all outbound traffic"
  vpc_id      = aws_vpc.vpc.id

  tags = merge(local.common_tags, {
    Name = "alb_security_group"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_allow_http" {
  security_group_id = aws_security_group.alb_sg.id
  prefix_list_id    = aws_cloudfront_distribution.cloudfront_alb.id
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.alb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}

resource "aws_lb_target_group" "backend_tg" {
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.vpc.id
}

resource "aws_lb" "nlb" {
  name                       = "nlb"
  internal                   = true
  load_balancer_type         = "network"
  subnets                    = [aws_subnet.private_subnets[2].id, aws_subnet.private_subnets[3].id]
  enable_deletion_protection = false

  tags = merge(local.common_tags, {
    Name     = "nlb"
    Internal = true
  })
}

resource "aws_lb_listener" "backend_lb_listener" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend_tg.arn
  }
}

resource "aws_lb_listener_rule" "nlb_rule_1" {
  listener_arn = aws_lb_listener.backend_lb_listener.arn
  priority     = 99

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend_tg.arn
  }

  condition {
    path_pattern {
      values = ["/"]
    }
  }
}

################################### RELATIONAL DATABASE ###################################

resource "aws_db_subnet_group" "db_subnets" {
  name       = "mysql database subnets"
  subnet_ids = [aws_subnet.private_subnets[4].id, aws_subnet.private_subnets[5].id]

  tags = {
    Name = "MySQL database subnets"
  }
}

data "aws_rds_engine_version" "mysql" {
  engine = "mysql"
  latest = true
}

resource "aws_db_instance" "mysql_instance" {
  allocated_storage      = 10
  db_name                = "mysql_db"
  identifier             = "mysql-db"
  engine                 = data.aws_rds_engine_version.mysql.engine
  engine_version         = data.aws_rds_engine_version.mysql.version
  instance_class         = var.db_instance_type
  username               = var.db_username
  password               = var.db_password
  multi_az               = true
  storage_encrypted      = true
  storage_type           = "gp3"
  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  publicly_accessible    = false

  tags = merge(local.common_tags, {
    Name = "mysql_db"
  })
}

resource "aws_security_group" "db_sg" {
  name        = "db_security_group"
  description = "Allow TLS inbound traffic and all outbound traffic"
  vpc_id      = aws_vpc.vpc.id

  tags = merge(local.common_tags, {
    Name = "db_security_group"
  })
}

resource "aws_vpc_security_group_ingress_rule" "db_allow_http" {
  security_group_id            = aws_security_group.db_sg.id
  referenced_security_group_id = aws_security_group.backend_sg.id
  from_port                    = 3306
  ip_protocol                  = "tcp"
  to_port                      = 3306
}

resource "aws_vpc_security_group_egress_rule" "db_allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.db_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}

################################### CLOUDFRONT & WAF ###################################

resource "aws_wafv2_web_acl" "waf_cf" {
  name        = "cloudfront-waf"
  description = "WAF for CloudFront"
  scope       = "CLOUDFRONT"
  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "cloudfrontWAF"
    sampled_requests_enabled   = true
  }

  rule {
    name     = "block-bad-bots"
    priority = 1

    action {
      block {}
    }

    statement {
      byte_match_statement {
        search_string = "BadBot"
        field_to_match {
          headers {
            match_pattern {
              all {}
            }
            match_scope       = "ALL"
            oversize_handling = "MATCH"
          }
        }
        text_transformation {
          priority = 0
          type     = "NONE"
        }
        positional_constraint = "CONTAINS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "blockBadBots"
      sampled_requests_enabled   = true
    }
  }
}

resource "aws_cloudfront_distribution" "cloudfront_alb" {
  origin {
    domain_name = aws_lb.alb.dns_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443         # Still required, even if unused
      origin_protocol_policy = "http-only" # Force HTTP from CloudFront to ALB
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "alb-origin"

    viewer_protocol_policy = "allow-all" # Allow HTTP and HTTPS from client to CloudFront

    forwarded_values {
      query_string = true

      cookies {
        forward = "all"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true # Will use *.cloudfront.net domain
  }

  web_acl_id = aws_wafv2_web_acl.waf_cf.id # Attach WAF to CloudFront
  comment    = "CloudFront with ALB origin using HTTP only and WAF attached"

  tags = merge(local.common_tags, {
    Name = "cloudfront_with_alb_and_waf"
  })
}

################################### CLOUDWATCH & SNS ###################################

resource "aws_autoscaling_policy" "frontend_as_policy_up" {
  name                   = "frontend-autoscaling-policy_up"
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.frontend_asg.name
  policy_type            = "StepScaling"
  step_adjustment {
    scaling_adjustment          = 1
    metric_interval_lower_bound = 0.0
  }
}

resource "aws_cloudwatch_metric_alarm" "frontend_asg_alarm_up" {
  alarm_name          = "frontend-autoscaling-group-alarm_up"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.frontend_asg.name
  }

  alarm_description = "Increase instance count when CPU > 80%"
  alarm_actions = [
    aws_autoscaling_policy.frontend_as_policy_up.arn,
    aws_sns_topic.ec2_cpu_utlization.arn
  ]
}

resource "aws_autoscaling_policy" "frontend_as_policy_down" {
  name                   = "frontend-autoscaling-policy"
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.frontend_asg.name
  policy_type            = "StepScaling"
  step_adjustment {
    scaling_adjustment          = -1
    metric_interval_lower_bound = 0.0
  }
}

resource "aws_cloudwatch_metric_alarm" "frontend_asg_alarm_down" {
  alarm_name          = "frontend-autoscaling-group-alarm_down"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 30

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.frontend_asg.name
  }

  alarm_description = "Decrease instance count when CPU < 30%"
  alarm_actions = [
    aws_autoscaling_policy.frontend_as_policy_down.arn,
    aws_sns_topic.ec2_cpu_utlization.arn
  ]
}

resource "aws_autoscaling_policy" "backend_as_policy_up" {
  name                   = "backend-autoscaling-policy_up"
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.backend_asg.name
  policy_type            = "StepScaling"
  step_adjustment {
    scaling_adjustment          = 1
    metric_interval_lower_bound = 0.0
  }
}

resource "aws_cloudwatch_metric_alarm" "backend_asg_alarm_up" {
  alarm_name          = "backend-autoscaling-group-alarm_up"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.backend_asg.name
  }

  alarm_description = "Increase instance count when CPU > 80%"
  alarm_actions = [
    aws_autoscaling_policy.backend_as_policy_up.arn,
    aws_sns_topic.ec2_cpu_utlization.arn
  ]
}

resource "aws_autoscaling_policy" "backend_as_policy_down" {
  name                   = "backend-autoscaling-policy"
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.backend_asg.name
  policy_type            = "StepScaling"
  step_adjustment {
    scaling_adjustment          = -1
    metric_interval_lower_bound = 0.0
  }
}

resource "aws_cloudwatch_metric_alarm" "backend_asg_alarm_down" {
  alarm_name          = "backend-autoscaling-group-alarm_down"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 30

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.backend_asg.name
  }

  alarm_description = "Decrease instance count when CPU < 30%"
  alarm_actions = [
    aws_autoscaling_policy.backend_as_policy_down.arn,
    aws_sns_topic.ec2_cpu_utlization.arn
  ]
}

resource "aws_cloudwatch_metric_alarm" "database_alarm" {
  alarm_name          = "database-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 120
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mysql_instance.id
  }

  alarm_description = "Notify admin when CPU > 80%"
  alarm_actions = [
    aws_sns_topic.ec2_cpu_utlization.arn
  ]
}

resource "aws_sns_topic" "ec2_cpu_utlization" {
  name = "ec2_cpu_utlization"
}

resource "aws_sns_topic_subscription" "ec2_cpu_utlization_email_target" {
  topic_arn = aws_sns_topic.ec2_cpu_utlization.arn
  protocol  = "email"
  endpoint  = var.sns_email
}

################################### ROUTE53 ###################################

resource "aws_route53_zone" "application_zone" {
  name = var.domain_name
}

resource "aws_route53_record" "cloudfront_record" {
  zone_id = aws_route53_zone.application_zone.id
  name    = "www.${var.domain_name}"
  type    = "CNAME"
  ttl     = 10
  records = [aws_cloudfront_distribution.cloudfront_alb.domain_name]
}
