# Shared storage for the WordPress document root.
#
# FSx for OpenZFS rather than EFS. Both are managed NFS; the difference is what
# a single file operation costs. EFS is serverless and charges per GB with no
# floor, but every call crosses a shared distributed service - measured here at
# roughly 130 file creations per second against 21,500 on local disk. FSx is a
# file server AWS operates, with provisioned disk and throughput and
# sub-millisecond latency.
#
# That matters because a WordPress document root is unusually operation-heavy.
# A plugin update deletes the old directory and unpacks the new one file by
# file: about 30,000 operations for something the size of WooCommerce, which is
# 225 seconds on EFS and roughly 9 on FSx. On EFS it exceeded CloudFront's
# origin timeout and failed outright.
#
# The trade is a cost floor. FSx bills for provisioned capacity whether it is
# used or not - about $24.64/month at the minimum Single-AZ configuration,
# against $0.28 for the EFS it replaces. It is not cheaper than EFS until total
# data passes roughly 82 GB; what it buys before that is speed.

resource "aws_security_group" "fsx" {
  name        = "${var.stack_name}-fsx"
  description = "NFS access to the FSx for OpenZFS file system from the web tier"
  vpc_id      = aws_vpc.bugfloyd.id

  ingress {
    description     = "NFS"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_web.id]
  }

  # rpcbind and the mount, status and lock daemons. NFS 4.1 negotiates
  # everything over 2049 and does not need these, but the mount command can
  # still probe them and the failure mode is a mount that hangs rather than one
  # that reports why.
  ingress {
    description     = "rpcbind"
    from_port       = 111
    to_port         = 111
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_web.id]
  }

  ingress {
    description     = "mountd, statd, lockd"
    from_port       = 20001
    to_port         = 20003
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_web.id]
  }

  # No egress. The file system only ever answers requests, and security groups
  # are stateful.

  tags = {
    Name       = "WebsitesFsxSecurityGroup"
    CostCenter = "Bugfloyd/Websites/Storage"
  }
}

resource "aws_fsx_openzfs_file_system" "websites" {
  # SINGLE_AZ_1 deliberately. SINGLE_AZ_2 starts at 160 MB/s of throughput
  # against this one's 64, which is $45.76/month rather than $18.30 for capacity
  # a low-traffic site will not use. Multi-AZ is $75.55 and belongs to v3, where
  # instances span two zones and a single-zone file system becomes the single
  # point of failure this stage accepts.
  deployment_type = "SINGLE_AZ_1"
  subnet_ids      = [aws_subnet.data_a.id]

  storage_type        = "SSD"
  storage_capacity    = var.fsx_storage_capacity
  throughput_capacity = var.fsx_throughput_capacity

  security_group_ids = [aws_security_group.fsx.id]

  # AWS Backup owns the schedule, as it does for the database. Setting this as
  # well would pay twice for the same recovery points.
  automatic_backup_retention_days = 0

  root_volume_configuration {
    # The document root is thousands of small PHP files that compress well and
    # are read far more often than written.
    data_compression_type = "ZSTD"

    # No root squash: the bootstrap sets ownership to uid 33 as it does today,
    # and needs to be able to.
    nfs_exports {
      client_configurations {
        clients = aws_vpc.bugfloyd.cidr_block
        options = ["crossmnt", "rw", "no_root_squash"]
      }
    }
  }

  tags = {
    Name       = "WebsitesFsx"
    CostCenter = "Bugfloyd/Websites/Storage"
  }
}

# Provisioned capacity does not grow on its own, which is the other half of the
# trade against EFS: it is faster, and it can fill up.
#
# There is no ready-made utilisation percentage for OpenZFS. FSx publishes
# StorageCapacity and UsedStorageCapacity in bytes and nothing else, so the
# percentage is computed here. The obvious-looking StorageCapacityUtilization
# does not exist for this file system type - an alarm on it sits in OK forever,
# because a metric that never reports looks exactly like a metric that is fine.
resource "aws_cloudwatch_metric_alarm" "fsx_storage_low" {
  alarm_name          = "${var.stack_name}-fsx-storage-high"
  alarm_description   = "FSx storage is running out. Unlike EFS this does not grow by itself"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  evaluation_periods  = 3
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "pct"
    expression  = "used / total * 100"
    label       = "Storage used (%)"
    return_data = true
  }

  metric_query {
    id = "used"
    metric {
      namespace   = "AWS/FSx"
      metric_name = "UsedStorageCapacity"
      dimensions  = { FileSystemId = aws_fsx_openzfs_file_system.websites.id }
      period      = 300
      stat        = "Average"
    }
  }

  metric_query {
    id = "total"
    metric {
      namespace   = "AWS/FSx"
      metric_name = "StorageCapacity"
      dimensions  = { FileSystemId = aws_fsx_openzfs_file_system.websites.id }
      period      = 300
      stat        = "Average"
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name       = "WebsitesFsxStorageAlarm"
    CostCenter = "Bugfloyd/Websites/Storage"
  }
}

resource "aws_cloudwatch_metric_alarm" "fsx_throughput" {
  alarm_name          = "${var.stack_name}-fsx-throughput-high"
  alarm_description   = "FSx is near its provisioned throughput; requests will queue"
  namespace           = "AWS/FSx"
  metric_name         = "NetworkThroughputUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    FileSystemId = aws_fsx_openzfs_file_system.websites.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name       = "WebsitesFsxThroughputAlarm"
    CostCenter = "Bugfloyd/Websites/Storage"
  }
}

output "fsx_file_system_id" {
  description = "FSx for OpenZFS file system backing the WordPress document root"
  value       = aws_fsx_openzfs_file_system.websites.id
}

output "fsx_dns_name" {
  description = "NFS endpoint for the file system"
  value       = aws_fsx_openzfs_file_system.websites.dns_name
}
