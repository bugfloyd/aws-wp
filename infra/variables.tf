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

variable "aws_region_backup" {
  default = "eu-west-1"
  type    = string
}

variable "backups_bucket_name" {
  description = "S3 bucket name for Backups"
  type        = string
}

variable "s3_backup_dir" {
  type    = string
  default = "wp-backups"
}

variable "cloudfront_logging_bucket_name" {
  description = "S3 bucket name for CloudFront logs"
  type        = string
}

variable "webserver_http_port" {
  type    = number
  default = 80
}