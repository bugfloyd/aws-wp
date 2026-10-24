resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.bugfloyd.id

  tags = {
    Name       = "BugfloydInternetGateway"
    CostCenter = "Bugfloyd/Network"
  }
}
