provider "aws" {
  region = "eu-west-1"

  default_tags {
    tags = {
      Owner   = "Bugfloyd"
      Service = "Bugfloyd/Websites"
    }
  }
}

variable "websites" {
  description = "List of domains for which hosted zones should be created"
  type        = list(string)
}

resource "aws_route53_zone" "this" {
  for_each = toset(var.websites)

  name = each.value

  tags = {
    Name       = "${join("", [for part in split(".", each.value) : title(part)])}HostedZone"
    CostCenter = "Bugfloyd/Network"
    Website    = each.value
  }
}

output "hosted_zone_ids" {
  description = "The IDs for the hosted zones"
  value       = { for domain, zone in aws_route53_zone.this : domain => zone.id }
}

output "hosted_zone_name_servers" {
  description = "The name servers for the hosted zones"
  value       = { for domain, zone in aws_route53_zone.this : domain => zone.name_servers }
}
