resource "aws_network_interface" "webserver" {
  subnet_id       = aws_subnet.public_a.id
  security_groups = [aws_security_group.ec2_web.id]

  tags = {
    Name       = "WebserverInstanceNetworkInterface"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

# Security Group for EC2 Instance
resource "aws_security_group" "ec2_web" {
  name        = "WebsitesInstanceSecurityGroupWeb"
  description = "Security Group for WordPress EC2 to allow HTTP from CloudFront only"
  vpc_id      = aws_vpc.bugfloyd.id

  ingress {
    description = "Allow HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow TCP 7080 from admin"
    from_port   = 7080
    to_port     = 7080
    protocol    = "tcp"
    cidr_blocks = var.admin_ips
  }

  ingress {
    description = "Allow SSH from Instance Connect"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_ips
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name       = "WebsitesInstanceSecurityGroupWeb"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}
