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

variable "disable_cache" {
  description = "Disable caching by using AWS Managed-CachingDisabled policy"
  type        = bool
  default     = false
}

variable "instance_public_dns" {
  description = "Public DNS name of the web server, used as the CloudFront origin"
  type        = string
}

variable "origin_http_port" {
  description = "Port the web server listens on"
  type        = number
  default     = 80
}

variable "policy_suffix" {
  description = "Appended to CloudFront cache and origin request policy names. These are unique account-wide, so a replacement stack running alongside an existing one needs its own"
  type        = string
  default     = ""
}

variable "origin_read_timeout" {
  description = "Seconds CloudFront waits for the origin to respond. 120 is the default account quota"
  type        = number
  default     = 120
}

variable "media_bucket_regional_domain_name" {
  description = "Regional domain name of this site's media bucket, used as the preferred origin for /wp-content/uploads/*"
  type        = string
}

variable "media_oac_id" {
  description = "Origin Access Control that lets this distribution read the media bucket"
  type        = string
}
