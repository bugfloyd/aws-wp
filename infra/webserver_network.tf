# resource "aws_network_interface" "webserver" {
#   subnet_id       = aws_subnet.private_a.id
#   security_groups = [aws_security_group.ec2_web.id]
#
#   tags = {
#     Name       = "WebserverInstanceNetworkInterface"
#     CostCenter = "Bugfloyd/Websites/Instance"
#   }
# }

# Security Group for EC2 Instance
resource "aws_security_group" "ec2_web" {
  name        = "WebsitesInstanceSecurityGroupWeb"
  description = "Security Group for WordPress EC2 to allow HTTP from LoadBalancer only"
  vpc_id      = aws_vpc.bugfloyd.id

  ingress {
    description     = "Allow HTTP from Load Balancer"
    from_port       = var.webserver_http_port
    to_port         = var.webserver_http_port
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer_sg.id]
  }

  ingress {
    description     = "Allow TCP 7080 from Load Balancer"
    from_port       = 7080
    to_port         = 7080
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer_sg.id]
  }

  ingress {
    description     = "Allow SSH from Instance Connect"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.instance_connect_endpoint_sg.id]
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

resource "aws_security_group" "instance_connect_endpoint_sg" {
  name        = "InstanceConnectEndpointSecurityGroup"
  description = "Security Group for WordPress EC2 instance connect endpoint"
  vpc_id      = aws_vpc.bugfloyd.id

  ingress {
    description = "Allow SSH access from a specific IP"
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
    Name       = "WebsitesInstanceConnectEndpointSecurityGroup"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

resource "aws_ec2_instance_connect_endpoint" "example" {
  subnet_id = aws_subnet.private_a.id
  security_group_ids = [aws_security_group.instance_connect_endpoint_sg.id]

  tags = {
    Name       = "WebsitesInstanceConnectEndpoint"
    CostCenter = "Bugfloyd/Websites"
  }
}