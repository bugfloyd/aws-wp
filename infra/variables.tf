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

variable "vpc_cidr" {
  description = "VPC range, from which the public and data subnets are carved as /24s. Must be private address space, and must not overlap another VPC this one may need to peer with"
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr must be a valid range of /16 or larger, so the /24 subnets fit."
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

  # Each domain names a media bucket, <stack_name>-<domain with dots as
  # hyphens>-media, and S3 bucket names are lowercase and at most 63 characters.
  validation {
    condition = alltrue([
      for d in keys(var.domains) :
      d == lower(d) && length("${var.stack_name}-${replace(d, ".", "-")}-media") <= 63
    ])
    error_message = "Domains must be lowercase, and <stack_name>-<domain>-media must fit S3's 63-character bucket name limit."
  }
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

variable "db_snapshot_identifier" {
  description = "Create the database from this RDS snapshot rather than empty. Used when a new stack takes over an existing one's data; ignored once the database exists"
  type        = string
  default     = null
}

variable "db_instance_class" {
  description = "RDS instance class. Note Performance Insights requires db.t4g.medium or larger"
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
  description = "Apply RDS modifications at once rather than holding them for the maintenance window. Fine in production if database changes are applied at a quiet hour; false defers them to Sunday's window"
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

variable "media_sync_interval" {
  description = "How often uploads are mirrored to S3, as a systemd time span. CloudFront falls back to the instance for anything not yet mirrored, so this is a performance knob rather than a data-loss window"
  type        = string
  default     = "10min"
}

variable "fsx_storage_capacity" {
  description = "GiB of SSD provisioned on the FSx file system. 64 is the minimum. Unlike EFS this does not grow on its own"
  type        = number
  default     = 64
}

variable "fsx_throughput_capacity" {
  description = "MB/s provisioned on the FSx file system, and the larger half of its cost at $0.286/MBps-month. 64 is the SINGLE_AZ_1 minimum; the valid steps are 64, 128, 256, 512 and up"
  type        = number
  default     = 64

  validation {
    condition     = contains([64, 128, 256, 512, 1024, 2048, 3072, 4096], var.fsx_throughput_capacity)
    error_message = "SINGLE_AZ_1 accepts 64, 128, 256, 512, 1024, 2048, 3072 or 4096 MB/s."
  }
}

variable "fsx_weekly_maintenance_start_time" {
  description = "When FSx may patch the file system each week, as d:HH:MM in UTC with 1 = Monday. A Single-AZ file system is unavailable for a few minutes during it, and every PHP request touching files waits (the mount is hard), so it is pinned to right after the database's own window rather than left where AWS happened to put it"
  type        = string
  default     = "7:04:30"

  validation {
    condition     = can(regex("^[1-7]:([01][0-9]|2[0-3]):[0-5][0-9]$", var.fsx_weekly_maintenance_start_time))
    error_message = "Use d:HH:MM, with d from 1 (Monday) to 7 (Sunday), in UTC."
  }
}

variable "php_settings" {
  description = "php.ini values applied at boot. The image ships PHP's own defaults, which are wrong for WordPress in visible ways - a 2 MB upload cap rejects an ordinary phone photo, and 30 seconds is too short for a large plugin update on network storage"
  type        = map(string)

  default = {
    memory_limit        = "256M"
    max_execution_time  = "300"
    max_input_time      = "300"
    upload_max_filesize = "64M"
    post_max_size       = "64M"
    max_input_vars      = "3000"

    # OPcache is what keeps the network file system off the read path: without
    # it every request re-reads and recompiles PHP source over NFS.
    "opcache.enable" = "1"

    # Headroom over the default 10,000. Three WordPress installs bring about
    # 16,400 PHP files, of which a couple of thousand are actually executed;
    # anything evicted is recompiled on the next request, from NFS.
    "opcache.max_accelerated_files"   = "20000"
    "opcache.memory_consumption"      = "160"
    "opcache.interned_strings_buffer" = "16"

    # Revalidation stats every cached file to see whether it changed. On a local
    # disk that is free; on NFS it is a network round trip, and the default of 2
    # seconds means doing it constantly. AWS recommends 900 for network file systems.
    #
    # Stale bytecode after an update is not a risk: WordPress calls
    # opcache_invalidate() on every file it writes during a plugin, theme or
    # core update, so its own changes take effect immediately regardless.
    # Changes made outside WordPress - editing wp-config.php by hand - do not:
    # restart OpenLiteSpeed after one.
    "opcache.validate_timestamps" = "1"
    "opcache.revalidate_freq"     = "900"
  }
}

variable "php_children" {
  description = "Ceiling on concurrent PHP requests for the whole server, and on LSPHP's regular workers. Children are forked on demand, so idle sites cost nothing - but the ceiling, plus php_extra_children, must fit in instance memory, because a burst can reach it. Each worker adds about 26 MB of shared pages, though ps reports around 95 MB"
  type        = number
  default     = 15
}

variable "php_extra_children" {
  description = "LSPHP workers allowed above php_children while workers left idle after a burst retire, so a burst clears in seconds. Set explicitly rather than left to LSAPI's default of php_children / 3, so the memory ceiling (php_children + this) is written down. 0 keeps php_children as a hard ceiling, at the cost of slower recovery from bursts"
  type        = number
  default     = 5

  validation {
    condition     = var.php_extra_children >= 0
    error_message = "php_extra_children cannot be negative."
  }
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

  # The alarm's period is the schedule's interval, and CloudWatch accepts
  # periods from a minute up to a day.
  validation {
    condition = try(
      tonumber(regex("^rate\\((\\d+) ", var.canary_schedule_expression)[0]) *
      (strcontains(var.canary_schedule_expression, "hour") ? 3600 : 60) <= 86400 &&
      tonumber(regex("^rate\\((\\d+) ", var.canary_schedule_expression)[0]) >= 1,
      false
    )
    error_message = "The canary must run between once a minute and once a day."
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
  description = "Seconds CloudFront waits for the origin. Admin actions that rewrite many files on network storage can exceed the 30-second default and surface as a 504. 120 is this account's \"Response timeout per origin\" quota, which is adjustable on request"
  type        = number
  default     = 120

  validation {
    condition     = var.origin_read_timeout >= 1 && var.origin_read_timeout <= 120
    error_message = "120 seconds is the default service quota for CloudFront's origin response timeout. Higher needs a quota increase request first."
  }
}

variable "page_cache_ttl" {
  description = "Seconds CloudFront keeps a public page before asking the origin again. Also the default TTL for responses that carry no Cache-Control"
  type        = number
  default     = 420

  validation {
    condition     = var.page_cache_ttl >= 0
    error_message = "page_cache_ttl cannot be negative."
  }
}

variable "page_stale_while_revalidate" {
  description = "Seconds after page_cache_ttl during which CloudFront answers with the old copy while it refreshes in the background. The oldest page a visitor can get is page_cache_ttl plus this. Keep it under 12 hours: WordPress nonces embedded in a page are only guaranteed valid for 12 (at most 24), so an older copy can carry expired ones and break the AJAX features of the first visitor after a quiet spell"
  type        = number
  default     = 39600

  validation {
    condition     = var.page_stale_while_revalidate >= 0 && var.page_stale_while_revalidate + var.page_cache_ttl <= 43200
    error_message = "page_cache_ttl + page_stale_while_revalidate must stay within 43200 seconds (12 hours), the shortest life of a WordPress nonce."
  }
}

variable "page_stale_if_error" {
  description = "Seconds CloudFront may keep serving an expired page while the origin is failing, such as during an instance replacement"
  type        = number
  default     = 86400
}

variable "media_browser_ttl" {
  description = "Seconds browsers keep year-folder media served from S3, which sends no Cache-Control of its own. A day matches what CloudFront keeps, so a file a plugin rewrites in place still reaches every visitor within a day"
  type        = number
  default     = 86400

  validation {
    condition     = var.media_browser_ttl >= 0
    error_message = "media_browser_ttl cannot be negative."
  }
}

variable "cache_bypass_cookie_prefixes" {
  description = "Cookie name prefixes that mark a request as personal: it is never served from the cache and its response is never shared. WordPress core, WooCommerce and Easy Digital Downloads by default; extend it for plugins with their own session cookies"
  type        = list(string)
  default = [
    "wordpress_logged_in_",
    "wordpress_sec_",
    "wp-postpass_",
    "comment_author_",
    "wordpress_no_cache",
    "woocommerce_items_in_cart",
    "woocommerce_cart_hash",
    "wp_woocommerce_session_",
    "edd_items_in_cart",
  ]

  validation {
    condition     = length(var.cache_bypass_cookie_prefixes) > 0 && alltrue([for p in var.cache_bypass_cookie_prefixes : length(p) > 3])
    error_message = "List at least one prefix, each longer than three characters; a short prefix would match unrelated cookies."
  }
}

variable "cache_ignored_query_strings" {
  description = "Query string parameters left out of the page cache key, so campaign links share one cached copy. They are still forwarded to WordPress on every origin request. A cache policy takes at most 10"
  type        = list(string)
  default     = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "gclid", "fbclid", "msclkid", "_gl", "mc_cid"]

  validation {
    condition     = length(var.cache_ignored_query_strings) <= 10
    error_message = "A CloudFront cache policy accepts at most 10 query string names."
  }
}

variable "edge_blocked_files" {
  description = "File names CloudFront answers with 403 wherever they appear in a path. wp-cron.php because cron runs on the instance itself; xmlrpc.php because nothing here uses it and it is a common brute-force target. Remove xmlrpc.php for the WordPress mobile app, Jetpack or pingbacks"
  type        = list(string)
  default     = ["wp-cron.php", "xmlrpc.php"]
}

variable "enforce_origin_secret" {
  description = "Make OpenLiteSpeed refuse requests that lack the origin secret header. Turn off for the apply that first adds the header to existing distributions, and while rotating it: CloudFront takes minutes to deploy a change everywhere, and an instance that enforces before every edge sends the right value answers live traffic with 403"
  type        = bool
  default     = true
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
  description = "Suffix for the names of CloudFront cache and origin request policies, CloudFront Functions and the origin access control, which are unique account-wide. They already carry stack_name; this is for two generations of a stack that share one, since the old distributions keep their policies and functions until they are deleted"
  type        = string
  default     = ""
}
