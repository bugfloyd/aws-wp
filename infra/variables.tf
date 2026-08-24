variable "region" {
  default = "eu-west-1"
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
  type    = number
  default = 80
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
  description = "Ceiling on LSPHP worker processes for the whole server. Children are forked on demand, so idle sites cost nothing - but the ceiling must fit in instance memory at roughly 40-60 MB each, because a burst can reach it. 12 leaves headroom on a 1 GiB instance"
  type        = number
  default     = 12
}

variable "instance_type" {
  description = "Web tier instance type. Memory is the binding constraint: it has to hold the OS, OpenLiteSpeed and php_children workers"
  type        = string
  default     = "t3.micro"
}

variable "asg_min_size" {
  description = "Minimum instances. At 1, an instance failure is a short outage while a replacement boots and bootstraps"
  type        = number
  default     = 1
}

variable "asg_desired_capacity" {
  description = "Instances to run in steady state"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Maximum instances. Must exceed desired_capacity, or a rolling refresh has no room to launch a replacement before retiring the old instance"
  type        = number
  default     = 2
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

variable "alert_email" {
  description = "Address that CloudWatch alarms notify. AWS sends a confirmation link that must be clicked once before anything is delivered"
  type        = string
}
