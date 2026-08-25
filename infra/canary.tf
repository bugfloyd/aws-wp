# A synthetic check against the origin.
#
# Every other alarm in this stack watches infrastructure: the instance's status
# checks, RDS free storage, EFS burst credits. None of them notice the failure
# that actually happens, which is the web server coming up misconfigured while
# the machine underneath it is fine. CloudFront makes that worse by continuing
# to serve cached pages, so the site looks up from outside.
#
# This is the only check here that makes a request the way a reader would.

locals {
  canary_domains = join(",", keys(var.domains))

  # The alarm's period has to match how often the canary actually runs. Leave
  # it hardcoded and a schedule change silently breaks the alarm: with a
  # five-minute period and an hourly canary, eleven windows out of twelve hold
  # no data at all, and treat_missing_data = "breaching" turns that into a
  # permanent alarm. Derive it so the two cannot drift apart.
  canary_rate           = regex("^rate\\((\\d+) (minute|minutes|hour|hours)\\)$", var.canary_schedule_expression)
  canary_period_seconds = tonumber(local.canary_rate[0]) * (startswith(local.canary_rate[1], "hour") ? 3600 : 60)
}

data "archive_file" "canary" {
  type        = "zip"
  output_path = "${path.module}/.terraform/tmp/canary.zip"

  source {
    # The runtime requires this exact layout: the handler is "<name>.handler"
    # and the file has to sit under nodejs/node_modules/.
    content  = file("${path.module}/templates/canary.js")
    filename = "nodejs/node_modules/origin_health.js"
  }
}

resource "aws_synthetics_canary" "origin" {
  count = var.enable_canary ? 1 : 0

  name                 = substr("${var.stack_name}-origin", 0, 21) # canary names cap at 21 chars
  artifact_s3_location = "s3://${aws_s3_bucket.cloudfront_logging_bucket.id}/canary/"
  execution_role_arn   = aws_iam_role.canary[0].arn
  runtime_version      = var.canary_runtime_version
  handler              = "origin_health.handler"
  zip_file             = data.archive_file.canary.output_path
  start_canary         = true

  schedule {
    expression = var.canary_schedule_expression
  }

  run_config {
    timeout_in_seconds = 60
    memory_in_mb       = 960
    environment_variables = {
      DOMAINS = local.canary_domains
    }
  }

  success_retention_period = 2
  failure_retention_period = 14

  tags = {
    Name       = "WebsitesOriginCanary"
    CostCenter = "Bugfloyd/Websites/Monitoring"
  }
}

resource "aws_cloudwatch_metric_alarm" "canary_failed" {
  count = var.enable_canary ? 1 : 0

  alarm_name        = "${var.stack_name}-origin-canary-failed"
  alarm_description = "The origin is not serving WordPress, whatever CloudFront may still be returning from cache"

  namespace   = "CloudWatchSynthetics"
  metric_name = "SuccessPercent"
  statistic   = "Average"
  period      = local.canary_period_seconds

  # One failed run is enough. Waiting for a second confirmation is the usual
  # way to suppress a single flaky check, but it costs one whole interval - at
  # an hourly cadence that is two hours before anyone hears, which is longer
  # than most outages worth hearing about. An occasional false email is the
  # cheaper mistake here.
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 100

  # A canary that stops reporting is itself a failure worth hearing about.
  treat_missing_data = "breaching"

  dimensions = {
    CanaryName = aws_synthetics_canary.origin[0].name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name       = "WebsitesOriginCanaryAlarm"
    CostCenter = "Bugfloyd/Websites/Monitoring"
  }
}
