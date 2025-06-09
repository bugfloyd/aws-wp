resource "aws_vpc" "bugfloyd" {
  cidr_block           = "20.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name       = "BugfloydVPC"
    CostCenter = "Bugfloyd/Network"
  }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.bugfloyd.id
  cidr_block              = "20.0.1.0/24"
  availability_zone       = element(data.aws_availability_zones.available.names, 0)
  map_public_ip_on_launch = true

  tags = {
    Name       = "BugfloydPublicSubnetA"
    CostCenter = "Bugfloyd/Network"
  }
}

resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.bugfloyd.id

  tags = {
    Name       = "BugfloydInternetGateway"
    CostCenter = "Bugfloyd/Network"
  }
}

resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.bugfloyd.id

  tags = {
    Name       = "BugfloydPublicRouteTable",
    CostCenter = "Bugfloyd/Network"
  }
}

resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.internet_gateway.id

  depends_on = [aws_internet_gateway.internet_gateway]
}

resource "aws_route_table_association" "public_subnet_a_association" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public_route_table.id
}

data "aws_availability_zones" "available" {}
