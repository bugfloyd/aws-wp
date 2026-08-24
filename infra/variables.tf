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
  description = "LSPHP worker processes for the whole server, shared by all virtual hosts. Bounded by instance memory (~40-60 MB each) and by the database's max_connections"
  type        = number
  default     = 20
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
