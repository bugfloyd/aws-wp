# Only CloudFront may reach the web server, and only on the port it serves.
#
# The managed prefix list covers CloudFront's origin-facing ranges, so the
# instance is publicly routable but not publicly reachable. TLS is terminated
# at CloudFront with an ACM certificate, which is why there is no 443 rule and
# no certificate on the instance at all.
resource "aws_security_group" "ec2_web" {
  name        = "WebsitesInstanceSecurityGroupWeb"
  description = "Security Group for the WordPress instance: HTTP from CloudFront, SSH from admin"
  vpc_id      = aws_vpc.bugfloyd.id

  ingress {
    description     = "Allow HTTP from CloudFront only"
    from_port       = var.webserver_http_port
    to_port         = var.webserver_http_port
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  # Fallback access. Session Manager is the usual route in - the agent is baked
  # into the image and needs no inbound rule at all - but a key-based login is
  # worth keeping for the case where the agent itself is what is broken.
  ingress {
    description = "Allow SSH from admin addresses"
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

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}
