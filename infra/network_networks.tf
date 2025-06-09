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
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name       = "BugfloydPublicSubnetA"
    CostCenter = "Bugfloyd/Network"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.bugfloyd.id
  cidr_block              = "20.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name       = "BugfloydPublicSubnetB"
    CostCenter = "Bugfloyd/Network"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id                  = aws_vpc.bugfloyd.id
  cidr_block              = "20.0.11.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name       = "BugfloydPrivateSubnetA"
    CostCenter = "Bugfloyd/Network"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = aws_vpc.bugfloyd.id
  cidr_block              = "20.0.12.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name       = "BugfloydPrivateSubnetB"
    CostCenter = "Bugfloyd/Network"
  }
}

data "aws_availability_zones" "available" {}
