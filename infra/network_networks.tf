resource "aws_vpc" "bugfloyd" {
  cidr_block           = "20.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name       = "BugfloydVPC"
    CostCenter = "Bugfloyd/Network"
  }
}

# The web server lives here, reachable from CloudFront over the internet
# gateway. No NAT gateway is needed because the instance has a public route of
# its own - which is also why this stage costs a third of what a private
# subnet plus NAT would.
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

# The data tier. RDS requires a subnet group spanning two Availability Zones
# even for a single-AZ instance, so these come in a pair; EFS mount targets sit
# here too. Neither needs a route off the VPC.
resource "aws_subnet" "data_a" {
  vpc_id                  = aws_vpc.bugfloyd.id
  cidr_block              = "20.0.21.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name       = "BugfloydDataSubnetA"
    CostCenter = "Bugfloyd/Network"
  }
}

resource "aws_subnet" "data_b" {
  vpc_id                  = aws_vpc.bugfloyd.id
  cidr_block              = "20.0.22.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name       = "BugfloydDataSubnetB"
    CostCenter = "Bugfloyd/Network"
  }
}

# Standard Availability Zones only. Without the filter this also returns Local
# Zones and Wavelength Zones, which cannot host subnets for these workloads and
# would make names[0] / names[1] non-deterministic.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
