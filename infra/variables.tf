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

variable "php_settings" {
  description = "php.ini values applied at boot. The image ships PHP's own defaults, which are wrong for WordPress in visible ways - a 2 MB upload cap rejects an ordinary phone photo, and 30 seconds is under half what a large plugin update needs against EFS"
  type        = map(string)

  default = {
    memory_limit        = "256M"
    max_execution_time  = "300"
    max_input_time      = "300"
    upload_max_filesize = "64M"
    post_max_size       = "64M"
    max_input_vars      = "3000"

    # OPcache is what keeps EFS off the read path: without it every request
    # re-reads and recompiles PHP source over NFS.
    "opcache.enable" = "1"

    # The default 10,000 does not fit the 16,400 PHP files three WordPress
    # installs bring. Anything past the limit is evicted and recompiled on the
    # next request, and each recompile is another round trip to EFS.
    "opcache.max_accelerated_files"   = "20000"
    "opcache.memory_consumption"      = "160"
    "opcache.interned_strings_buffer" = "16"

    # Revalidation stats every cached file to see whether it changed. On a local
    # disk that is free; on NFS it is a network round trip, and the default of 2
    # seconds means doing it constantly. AWS recommends 900 for EFS.
    #
    # Stale bytecode after an update is not a risk: WordPress calls
    # opcache_invalidate() on every file it writes during a plugin, theme or
    # core update, so its own changes take effect immediately regardless.
    "opcache.validate_timestamps" = "1"
    "opcache.revalidate_freq"     = "900"
  }
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
  description = "How often the canary runs, as rate(N minutes) or rate(N hours). Runs are billed individually at $0.0014 each: hourly is about $1/month, every 15 minutes about $4, every 5 minutes about $12. The alarm period is derived from this, so the two cannot drift apart"
  type        = string
  default     = "rate(1 hour)"

  validation {
    condition     = can(regex("^rate\\((\\d+) (minute|minutes|hour|hours)\\)$", var.canary_schedule_expression))
    error_message = "Must be rate(N minutes) or rate(N hours) - the alarm period is derived from it by parsing."
  }
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

variable "origin_read_timeout" {
  description = "Seconds CloudFront waits for the origin. Admin actions that rewrite many files on EFS are slow enough to exceed the 30-second default and surface as a 504. 120 is this account's \"Response timeout per origin\" quota, which is adjustable on request"
  type        = number
  default     = 120

  validation {
    condition     = var.origin_read_timeout >= 1 && var.origin_read_timeout <= 120
    error_message = "120 seconds is the default service quota for CloudFront's origin response timeout. Higher needs a quota increase request first."
  }
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
