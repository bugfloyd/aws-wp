resource "aws_key_pair" "websites_key_pair" {
  key_name   = "WebsitesKeyPair"
  public_key = var.admin_public_key

  tags = {
    Name       = "WebsitesInstanceKeyPair"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

resource "aws_instance" "webserver" {
  ami           = var.ols_image_id
  instance_type = "t3.small"
  key_name      = aws_key_pair.websites_key_pair.key_name

  network_interface {
    network_interface_id = aws_network_interface.webserver.id
    device_index         = 0
  }

  root_block_device {
    volume_size = 20
  }

  tags = {
    Name       = "WebserverInstance"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

resource "aws_route53_record" "main_dns_record" {
  for_each = var.domains

  zone_id = each.value
  name    = each.key
  type    = "A"
  ttl     = 300
  records = [aws_instance.webserver.public_ip]
}

resource "aws_route53_record" "www_dns_record" {
  for_each = var.domains

  zone_id = each.value
  name    = "www.${each.key}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.webserver.public_ip]
}

output "webserver_instance_ip" {
  description = "The public IP address of the webserver EC2 instance"
  value       = aws_instance.webserver.public_ip
}
