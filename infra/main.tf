provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Owner   = "Bugfloyd"
      Service = "Bugfloyd/Websites"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1" # ACM for CloudFront must be in us-east-1
}

module "websites_cert_cloudfront_dns" {
  source = "./cert_cloudfront_dns"

  for_each = var.domains

  domain              = each.key
  hosted_zone_id      = each.value
  logging_bucket      = aws_s3_bucket.cloudfront_logging_bucket.id
  load_balancer_arn   = aws_lb.load_balancer.arn
  lb_websites_tg_arn  = aws_lb_target_group.lb_target_group_websites.arn
  lb_ols_admin_tg_arn = aws_lb_target_group.lb_target_group_ols_admin.arn
  lb_dns_name         = aws_lb.load_balancer.dns_name
  disable_cache       = true

  providers = {
    aws.us_east_1 = aws.us_east_1
  }
}

