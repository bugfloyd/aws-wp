output "configuration_set_name" {
  description = "Configuration set every identity sends through by default"
  value       = aws_sesv2_configuration_set.sites.configuration_set_name
}

output "events_topic_arn" {
  description = "SNS topic that receives bounce, complaint and reject events"
  value       = aws_sns_topic.events.arn
}
