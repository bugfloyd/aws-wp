variable "region" {
  default = "eu-west-1"
}

variable "stack_name" {
  description = "Prefix for every resource name whose uniqueness scope is wider than the VPC. Security groups are left out deliberately - their names are unique per VPC, and each stack builds its own, so they cannot collide"
  type        = string
  default     = "websites"

  validation {
    # The narrowest rule any resource using this imposes is the RDS
    # identifier: lowercase alphanumerics and hyphens, starting with a letter.
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.stack_name))
    error_message = "stack_name must be 2-24 characters of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "ols_image_id" {
  description = "The ID of the AMI to be used for EC2 instance"
  type        = string
}

variable "admin_ips" {
  description = "IP address of the admin to be whitelisted to provide SSH access"
  type        = list(string)
}

variable "admin_public_key" {
  description = "Public key of the admin to provide SSH access"
  type        = string
}

variable "domains" {
  description = "Map of domain names to their Route 53 hosted zone IDs"
  type        = map(string)
}

variable "cloudfront_logging_bucket_name" {
  description = "S3 bucket name for CloudFront logs"
  type        = string
}

variable "webserver_http_port" {
  description = "Port OpenLiteSpeed listens on. CloudFront reaches it over plain HTTP; TLS is terminated at the edge"
  type        = number
  default     = 80
}
variable "db_engine_version" {
  description = "MySQL major version, major.minor only so RDS applies the current patch release. Track the current LTS - a version past its RDS end of standard support is auto-enrolled in Extended Support and billed per vCPU-hour, which costs several times the instance itself"
  type        = string
  default     = "8.4"
}

variable "db_instance_class" {
  description = "RDS instance class. Note Performance Insights requires db.t4g.small or larger"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GB. gp3 has a 20 GB minimum"
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Ceiling for RDS storage autoscaling in GB"
  type        = number
  default     = 100
}

variable "db_backup_retention_days" {
  description = "Days of RDS automated backups to retain. Maximum is 35"
  type        = number
  default     = 30
}

variable "db_apply_immediately" {
  description = "Apply RDS modifications at once rather than in the maintenance window. Should be false in production"
  type        = bool
  default     = true
}

variable "db_deletion_protection" {
  description = "Block accidental deletion of the database. Should be true in production"
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Should be false in production"
  type        = bool
  default     = true
}

variable "php_children" {
  description = "Ceiling on LSPHP worker processes for the whole server. Children are forked on demand, so idle sites cost nothing - but the ceiling must fit in instance memory at roughly 40-60 MB each, because a burst can reach it"
  type        = number
  default     = 15
}

variable "instance_type" {
  description = "Web tier instance type. Memory is the binding constraint: it has to hold the OS, OpenLiteSpeed and php_children workers"
  type        = string
  default     = "t3.micro"
}

variable "enable_ols_cache" {
  description = "Turn on the OpenLiteSpeed server cache module. The Cached stage enables this alongside the LiteSpeed Cache plugin"
  type        = bool
  default     = false
}

variable "config_bucket_name" {
  description = "S3 bucket holding the rendered OpenLiteSpeed configuration the instances fetch at boot"
  type        = string
}

variable "enable_canary" {
  description = "Run a CloudWatch Synthetics canary against the origin. The only check here that fails when the web server is broken but the instance is healthy"
  type        = bool
  default     = true
}

variable "canary_schedule_expression" {
  description = "How often the canary runs. Runs are billed individually - at $0.0014 each, every 5 minutes is about $12/month and every 15 minutes about $4, against a stack that otherwise costs roughly $33"
  type        = string
  default     = "rate(15 minutes)"
}

variable "canary_runtime_version" {
  description = "Synthetics runtime. AWS deprecates these on a schedule, so it is pinned rather than floating - check for a newer one when revisiting"
  type        = string
  default     = "syn-nodejs-puppeteer-17.0"
}

variable "alert_email" {
  description = "Address that CloudWatch alarms notify. AWS sends a confirmation link that must be clicked once before anything is delivered"
  type        = string
}

variable "enable_edge" {
  description = "Create the per-domain ACM certificates, CloudFront distributions and DNS records. Set false to build the server without claiming domains a live stack still serves"
  type        = bool
  default     = true
}

variable "key_pair_name" {
  description = "Overrides the key pair name, which defaults to \"<stack_name>-key\". Worth pinning on an existing stack: the name is unique per region, and changing it replaces the instance"
  type        = string
  default     = null
}

variable "edge_policy_suffix" {
  description = "Suffix for CloudFront cache and origin request policy names, which are unique account-wide. Separate from stack_name because these are the one set of names that has to differ from a stack being replaced while both are live - the old distributions keep their policies until they are deleted"
  type        = string
  default     = ""
}
