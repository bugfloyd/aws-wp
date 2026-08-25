resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.bugfloyd.id

  tags = {
    Name       = "BugfloydPublicRouteTable"
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

# Data
# Deliberately no default route. RDS and EFS need only local VPC routing, so
# the data tier has no path to the internet at all.
resource "aws_route_table" "data_route_table" {
  vpc_id = aws_vpc.bugfloyd.id

  tags = {
    Name       = "BugfloydDataRouteTable"
    CostCenter = "Bugfloyd/Network"
  }
}

resource "aws_route_table_association" "data_subnet_a_association" {
  subnet_id      = aws_subnet.data_a.id
  route_table_id = aws_route_table.data_route_table.id
}

resource "aws_route_table_association" "data_subnet_b_association" {
  subnet_id      = aws_subnet.data_b.id
  route_table_id = aws_route_table.data_route_table.id
}
