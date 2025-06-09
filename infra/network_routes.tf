# Public
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

resource "aws_route_table_association" "public_subnet_b_association" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_route_table.id
}


# Private
resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.bugfloyd.id

  tags = {
    Name       = "BugfloydPrivateRouteTable"
    CostCenter = "Bugfloyd/Network"
  }
}

resource "aws_route" "private_route" {
  route_table_id         = aws_route_table.private_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_gateway.id

  depends_on = [aws_nat_gateway.nat_gateway]
}

resource "aws_route_table_association" "private_subnet_a_association" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_route_table.id
}

resource "aws_route_table_association" "private_subnet_b_association" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_route_table.id
}
