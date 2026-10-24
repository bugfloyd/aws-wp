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

# The platform's own domain, for names that belong to no single site: the names
# CloudFront reaches each site's origin by, <site>.origin.<platform_domain>. They
# live here rather than in each site's zone so that a site whose DNS is hosted
# elsewhere - another AWS account, Cloudflare, a registrar - never has to hold a
# record pointing at the instance.
variable "platform_domain" {
  description = "Domain whose hosted zone holds the platform's own names, such as each site's origin name. null creates none"
  type        = string
  default     = null
}

resource "aws_route53_zone" "platform" {
  count = var.platform_domain == null ? 0 : 1

  name = var.platform_domain

  tags = {
    Name       = "${join("", [for part in split(".", var.platform_domain) : title(part)])}HostedZone"
    CostCenter = "Bugfloyd/Network"
  }

  # Every site's distribution finds the instance through this zone, so losing it
  # fails every uncached request on every site at once. A recreated zone gets new
  # name servers, and the domain stays dark until the registrar is updated.
  lifecycle {
    prevent_destroy = true
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

output "platform_zone_id" {
  description = "The ID of the platform domain's hosted zone, which infra/ needs as origin_zone_id"
  value       = one(aws_route53_zone.platform[*].id)
}

output "platform_zone_name_servers" {
  description = "The name servers to delegate the platform domain to, at its registrar"
  value       = one(aws_route53_zone.platform[*].name_servers)
}
