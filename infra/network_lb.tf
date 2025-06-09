resource "aws_security_group" "load_balancer_sg" {
  name        = "LoadBalancerSecurityGroup"
  description = "Security Group for websites ALB"
  vpc_id      = aws_vpc.bugfloyd.id

  # Inbound rules
  ingress {
    description = "Allow HTTPS from CloudFront"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  ingress {
    description = "Allow TCP 7080 from a specific IP"
    from_port   = 7080
    to_port     = 7080
    protocol    = "tcp"
    cidr_blocks = var.admin_ips
  }

  # Outbound rules (Allow all traffic)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name       = "WebsitesLoadBalancerSecurityGroup"
    CostCenter = "Bugfloyd/Websites/Network"
  }
}

# Application Load Balancer (ALB)
resource "aws_lb" "load_balancer" {
  name               = "websites-alb"
  internal           = false # Internet-facing
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load_balancer_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  ip_address_type    = "ipv4"

  enable_deletion_protection = false

  tags = {
    Name       = "WebsitesLoadBalancer"
    CostCenter = "Bugfloyd/Websites/Network"
  }
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

