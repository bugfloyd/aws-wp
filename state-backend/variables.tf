variable "region" {
  description = "Region holding the infrastructure state bucket"
  type        = string
  default     = "eu-west-1"
}

variable "infra_state_bucket" {
  description = "Bucket holding the state for infra/, including its workspaces"
  type        = string
}

variable "zones_state_bucket" {
  description = "Bucket holding the state for hostedzones/. Separate, and in another region, for historical reasons - see README"
  type        = string
}

variable "zones_state_bucket_region" {
  description = "Region of the hosted zones state bucket"
  type        = string
  default     = "eu-central-1"
}
