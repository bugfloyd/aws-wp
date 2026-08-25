# Shared storage for the WordPress document root.
#
# Every instance in the Auto Scaling group mounts the file system root at
# /var/www, so the site files live independently of any single instance. This is
# what makes the instances disposable.
#
# Mounted with the stock NFS 4.1 client rather than amazon-efs-utils, which is
# not packaged for Ubuntu and needs a Rust/Go/CMake toolchain to build. That
# rules out EFS access points, whose mount option is efs-utils specific, so
# ownership is set by the bootstrap instead of enforced server side.

resource "aws_security_group" "efs" {
  name        = "WebsitesEfsSecurityGroup"
  description = "Security Group for the WordPress EFS mount targets"
  vpc_id      = aws_vpc.bugfloyd.id

  ingress {
    description     = "Allow NFS from the web tier"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_web.id]
  }

  # No egress. Mount targets only ever answer requests, and security groups are
  # stateful, so replies to the web tier are allowed without a rule.

  tags = {
    Name       = "WebsitesEfsSecurityGroup"
    CostCenter = "Bugfloyd/Websites/Storage"
  }
}

resource "aws_efs_file_system" "websites" {
  # The creation token is an idempotency key, not a label: creating a file
  # system with a token that already exists returns the existing one rather
  # than failing. Two stacks sharing a token would therefore silently share
  # storage - a worse failure than a name clash, because nothing reports it.
  #
  # It is also create-only. Changing it on a live file system would destroy
  # every site file, so an existing stack keeps whatever token it was built
  # with and only new stacks pick the derived name.
  creation_token = "${var.stack_name}-efs"
  encrypted      = true

  lifecycle {
    ignore_changes = [creation_token]
  }

  # Set both explicitly rather than inheriting AWS defaults, which have changed
  # over time. Bursting throughput is predictable and free; Elastic bills per
  # request, which is hard to forecast for a demo.
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = {
    Name       = "WebsitesEfs"
    CostCenter = "Bugfloyd/Websites/Storage"
  }
}

# One mount target per AZ, in the data subnets, matching where the web tier runs.
resource "aws_efs_mount_target" "data_a" {
  file_system_id  = aws_efs_file_system.websites.id
  subnet_id       = aws_subnet.data_a.id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_mount_target" "data_b" {
  file_system_id  = aws_efs_file_system.websites.id
  subnet_id       = aws_subnet.data_b.id
  security_groups = [aws_security_group.efs.id]
}

# Bursting throughput spends credits whenever sustained throughput exceeds the
# baseline the file system earns from its size. WordPress core and plugin
# updates touch thousands of small files and can drain them quickly. Once the
# balance hits zero, throughput is throttled to baseline and the site crawls.
resource "aws_cloudwatch_metric_alarm" "efs_burst_credits_low" {
  alarm_name          = "${var.stack_name}-efs-burst-credits-low"
  alarm_description   = "EFS burst credit balance is dropping; sustained throughput will be throttled once it reaches zero"
  namespace           = "AWS/EFS"
  metric_name         = "BurstCreditBalance"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 1099511627776 # 1 TiB, roughly half the starting balance
  treat_missing_data  = "notBreaching"

  dimensions = {
    FileSystemId = aws_efs_file_system.websites.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]



  tags = {
    Name       = "WebsitesEfsBurstCreditsAlarm"
    CostCenter = "Bugfloyd/Websites/Storage"
  }
}

# General Purpose mode caps at 35,000 file operations per second. A WordPress
# document root on shared storage is unusually operation-heavy, so this is the
# other way EFS degrades before it runs out of anything visible.
resource "aws_cloudwatch_metric_alarm" "efs_io_limit" {
  alarm_name          = "${var.stack_name}-efs-io-limit-high"
  alarm_description   = "EFS is approaching the General Purpose file operations limit"
  namespace           = "AWS/EFS"
  metric_name         = "PercentIOLimit"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    FileSystemId = aws_efs_file_system.websites.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name       = "WebsitesEfsIoLimitAlarm"
    CostCenter = "Bugfloyd/Websites/Storage"
  }
}

output "efs_file_system_id" {
  description = "EFS file system backing the WordPress document root"
  value       = aws_efs_file_system.websites.id
}
