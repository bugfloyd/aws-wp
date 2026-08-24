# The web server.
#
# One instance, deliberately. This stage is about removing state from the
# instance, not about running several of them - the Scalable stage introduces
# a load balancer and an Auto Scaling group. Keeping the shape of the previous
# stage means the difference between them is exactly the thing being taught.
#
# Everything that makes this instance serve a site happens in user_data at
# first boot, so it can be destroyed and recreated without losing anything.

resource "aws_key_pair" "websites_key_pair" {
  key_name   = "WebsitesKeyPair"
  public_key = var.admin_public_key

  tags = {
    Name       = "WebsitesInstanceKeyPair"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

resource "aws_instance" "webserver" {
  ami                    = var.ols_image_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.ec2_web.id]
  key_name               = aws_key_pair.websites_key_pair.key_name
  iam_instance_profile   = aws_iam_instance_profile.ols_instance_profile.name

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = local.bootstrap

  # Rebuild the instance when the bootstrap changes, rather than leaving a
  # running box configured by a script it no longer matches. This is what keeps
  # the instance disposable in practice and not just in principle.
  user_data_replace_on_change = true

  tags = {
    Name       = "WebserverInstance"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

# CloudFront needs an origin hostname that survives the instance being
# replaced. Without an Elastic IP the public DNS name changes on every rebuild
# and every distribution silently points at nothing.
resource "aws_eip" "webserver" {
  instance = aws_instance.webserver.id
  domain   = "vpc"

  tags = {
    Name       = "WebserverElasticIP"
    CostCenter = "Bugfloyd/Websites/Instance"
  }

  depends_on = [aws_internet_gateway.internet_gateway]
}

output "webserver_public_ip" {
  description = "Stable public address of the web server"
  value       = aws_eip.webserver.public_ip
}

output "webserver_public_dns" {
  description = "Origin hostname the CloudFront distributions point at"
  value       = aws_eip.webserver.public_dns
}
