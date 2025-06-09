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
