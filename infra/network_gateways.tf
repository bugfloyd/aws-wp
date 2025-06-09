# Internet Gateway
resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.bugfloyd.id

  tags = {
    Name       = "BugfloydInternetGateway"
    CostCenter = "Bugfloyd/Network"
  }
}

# NAT Gateway (for Private Subnet Internet Access)
resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat_gateway_eip.id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name       = "BugfloydNATGateway"
    CostCenter = "Bugfloyd/Network"
  }

  depends_on = [aws_internet_gateway.internet_gateway]
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat_gateway_eip" {
  domain = "vpc"

  tags = {
    Name       = "BugfloydNatGatewayElasticIP"
    CostCenter = "Bugfloyd/Network"
  }
}
