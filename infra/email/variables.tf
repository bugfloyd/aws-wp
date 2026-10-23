variable "name" {
  description = "Name of the configuration set, and the prefix of the events topic"
  type        = string
}

variable "domains" {
  description = "Map of domain names to their Route 53 hosted zone IDs"
  type        = map(string)
}

variable "mail_from_subdomain" {
  description = "Subdomain of each domain used as the envelope sender"
  type        = string
}

variable "dmarc_record" {
  description = "The _dmarc TXT record for every domain, or null for none"
  type        = string
  default     = null
}
