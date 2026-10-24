variable "name" {
  description = "Name of the configuration set, and the prefix of the events topic"
  type        = string
}

variable "domains" {
  description = "The domains to make SES identities, each with the Route 53 hosted zone its records are written into - null for DNS hosted elsewhere, whose records go to dns_records instead - and its DMARC record, null for none"
  type = map(object({
    zone_id      = string
    dmarc_record = string
  }))
}

variable "mail_from_subdomain" {
  description = "Subdomain of each domain used as the envelope sender"
  type        = string
}

