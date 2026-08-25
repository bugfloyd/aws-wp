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
  name         = "${var.stack_name}-alerts"
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

# Instance health.
#
# This replaces the load balancer's target health check, which does not exist
# at this stage. It is a weaker signal and worth being honest about: it catches
# the instance being dead, not the web server being broken while the instance
# is fine. The Scalable stage restores a real health check by putting a load
# balancer in front, which also lets a failed instance be replaced rather than
# merely reported.
resource "aws_cloudwatch_metric_alarm" "instance_status" {
  alarm_name          = "${var.stack_name}-instance-status-failed"
  alarm_description   = "The web server instance is failing its EC2 status checks"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = aws_instance.webserver.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name       = "WebsitesInstanceStatusAlarm"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

# Storage autoscaling handles growth, but only up to var.db_max_allocated_storage.
resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "${var.stack_name}-rds-storage-low"
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
