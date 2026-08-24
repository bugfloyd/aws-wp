# Somewhere for alarms to go.
#
# Without this the CloudWatch alarms change state and nobody hears: an alarm
# with no action is a dashboard widget, not a notification.
#
# Email is the least machinery that actually works. The subscription needs one
# manual confirmation click - AWS emails a link, and Terraform cannot accept it
# on your behalf, so the subscription sits in "pending confirmation" until you
# do. It does not fail the apply, and nothing is delivered until confirmed.

resource "aws_sns_topic" "alerts" {
  name         = "websites-alerts"
  display_name = "Websites"

  tags = {
    Name       = "WebsitesAlertsTopic"
    CostCenter = "Bugfloyd/Websites"
  }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# The load balancer's own view of whether the site is up.
#
# This is the alarm that would have caught the bug where every health check
# received a 404 because the check addresses targets by IP and cannot send a
# Host header. The site still answered for a human hitting the real domain, so
# the only visible symptom was instances being replaced forever.
resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "websites-unhealthy-targets"
  alarm_description   = "One or more web instances are failing their load balancer health check"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.load_balancer.arn_suffix
    TargetGroup  = aws_lb_target_group.lb_target_group_websites.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name       = "WebsitesUnhealthyTargetsAlarm"
    CostCenter = "Bugfloyd/Websites/Network"
  }
}

# Storage autoscaling handles growth, but only up to var.db_max_allocated_storage.
resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "websites-rds-storage-low"
  alarm_description   = "RDS free storage is running low"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 2147483648 # 2 GiB
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.websites.identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name       = "WebsitesRdsStorageAlarm"
    CostCenter = "Bugfloyd/Websites/Database"
  }
}

output "alerts_topic_arn" {
  description = "SNS topic the alarms publish to"
  value       = aws_sns_topic.alerts.arn
}
