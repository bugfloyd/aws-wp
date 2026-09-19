variable "region" {
  description = "Region holding the Terraform state bucket"
  type        = string
  default     = "eu-west-1"
}

variable "infra_state_bucket" {
  description = "Bucket holding the state for infra/, including its workspaces"
  type        = string
}


