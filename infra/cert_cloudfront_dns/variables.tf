variable "domain" {
  description = "Domain name for SSL certificate and redirects"
  type        = string
}

variable "hosted_zone_id" {
  description = "The Hosted Zone ID for the domain"
  type        = string
}

variable "logging_bucket" {
  description = "S3 bucket used for CloudFront distribution logs"
  type        = string
}

variable "load_balancer_arn" {
  description = "Load balancer ARN"
  type        = string
}

variable "lb_websites_tg_arn" {
  type        = string
}

variable "lb_ols_admin_tg_arn" {
  type        = string
}

variable "lb_dns_name" {
  type        = string
}

variable "disable_cache" {
  description = "Disable caching by using AWS Managed-CachingDisabled policy"
  type        = bool
  default     = false
}
