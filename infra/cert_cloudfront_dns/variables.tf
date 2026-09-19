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

variable "instance_public_ip" {
  description = "Elastic IP of the web server. Published as origin.<domain>, which CloudFront uses to reach it"
  type        = string
}

variable "origin_http_port" {
  description = "Port the web server listens on"
  type        = number
  default     = 80
}

variable "origin_secret" {
  description = "Sent to the instance in X-Origin-Verify, proving a request came from this stack's distributions rather than merely from CloudFront"
  type        = string
  sensitive   = true
}

variable "origin_read_timeout" {
  description = "Seconds CloudFront waits for the origin to respond. 120 is the default account quota"
  type        = number
  default     = 120
}

variable "media_bucket_regional_domain_name" {
  description = "Regional domain name of this site's media bucket, used as the preferred origin for year-folder media, /wp-content/uploads/20??/*"
  type        = string
}

variable "media_oac_id" {
  description = "Origin Access Control that lets this distribution read the media bucket"
  type        = string
}

variable "pages_cache_policy_id" {
  description = "Shared cache policy for pages, on the default behavior"
  type        = string
}

variable "origin_request_policy_id" {
  description = "Shared origin request policy: every cookie, query string and viewer header reaches WordPress"
  type        = string
}

variable "viewer_request_function_arn" {
  description = "CloudFront Function that marks personal requests and blocks public cron and XML-RPC"
  type        = string
}

variable "viewer_response_function_arn" {
  description = "CloudFront Function that tells browsers no-cache for pages CloudFront keeps with stale directives"
  type        = string
}
