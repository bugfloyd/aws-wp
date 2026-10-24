# A private range. The original 20.0.0.0/16 was public address space belonging to
# Microsoft, so any request from inside the VPC to an address in it - an Azure-
# hosted API a plugin calls, say - was routed locally and never left. It only
# fails for the unlucky destination, which is what made it easy to miss.
#
# Subnets are carved from it rather than written out, so changing the range is one
# variable. Changing it on a live stack replaces the VPC and everything in it.
resource "aws_vpc" "bugfloyd" {
  cidr_block           = var.vpc_cidr
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
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name       = "BugfloydPublicSubnetA"
    CostCenter = "Bugfloyd/Network"
  }
}

# The data tier. RDS requires a subnet group spanning two Availability Zones
# even for a single-AZ instance, so these come in a pair; the file system sits in
# data_a. Neither needs a route off the VPC.
resource "aws_subnet" "data_a" {
  vpc_id                  = aws_vpc.bugfloyd.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 21)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name       = "BugfloydDataSubnetA"
    CostCenter = "Bugfloyd/Network"
  }
}

resource "aws_subnet" "data_b" {
  vpc_id                  = aws_vpc.bugfloyd.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 22)
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
