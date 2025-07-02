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
  cidr_ipv4         = "0.0.0.0/0"
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