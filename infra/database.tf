# Managed database for WordPress.
#
# Moving the database off the instances is the other half of making them
# disposable. The AMI still ships MariaDB in the standalone profile, but the
# web profile does not run it — WordPress talks to this instead.

resource "aws_security_group" "rds" {
  name        = "WebsitesRdsSecurityGroup"
  description = "Security Group for the WordPress RDS instance"
  vpc_id      = aws_vpc.bugfloyd.id

  ingress {
    description     = "Allow MySQL from the web tier"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_web.id]
  }

  # No egress, same reasoning as the file system's security group.

  tags = {
    Name       = "WebsitesRdsSecurityGroup"
    CostCenter = "Bugfloyd/Websites/Database"
  }
}

resource "aws_db_subnet_group" "websites" {
  name       = "${var.stack_name}-db-subnet-group"
  subnet_ids = [aws_subnet.data_a.id, aws_subnet.data_b.id]

  # RDS requires subnets in at least two Availability Zones even for a
  # single-AZ instance, which is why the data tier is built as a pair.

  tags = {
    Name       = "WebsitesDbSubnetGroup"
    CostCenter = "Bugfloyd/Websites/Database"
  }
}

resource "aws_db_parameter_group" "websites" {
  name        = "${var.stack_name}-mysql${replace(var.db_engine_version, ".", "")}"
  family      = "mysql${var.db_engine_version}"
  description = "WordPress tuning for MySQL ${var.db_engine_version}"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  # Automated backups turn on binary logging. Without this, any plugin that
  # creates a stored function or trigger fails with ERROR 1419, which is a
  # confusing thing to hit weeks after launch.
  parameter {
    name  = "log_bin_trust_function_creators"
    value = "1"
  }

  # The slow query log, exported to CloudWatch Logs (see the log group below).
  # Both are dynamic: turning them on or changing the threshold needs no
  # reboot. A second is slow for any WordPress query on a database this size;
  # the usual finds are unindexed meta lookups and oversized autoloaded options.
  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }

  # The log group has to exist before RDS first exports to it (see below).
  depends_on = [aws_cloudwatch_log_group.db_slowquery]

  tags = {
    Name       = "WebsitesDbParameterGroup"
    CostCenter = "Bugfloyd/Websites/Database"
  }
}

# RDS creates the log group for an exported log the first time it writes to
# it, with no retention: slow queries would be kept forever. Created here first,
# so it has one. The name is RDS's own convention and must match the instance
# identifier; the error log's group predates this and still never expires.
resource "aws_cloudwatch_log_group" "db_slowquery" {
  name              = "/aws/rds/instance/${var.stack_name}-mysql/slowquery"
  retention_in_days = 90

  tags = {
    Name       = "WebsitesDbSlowQueryLog"
    CostCenter = "Bugfloyd/Websites/Database"
  }
}

resource "aws_db_instance" "websites" {
  identifier = "${var.stack_name}-mysql"

  engine = "mysql"
  # Major.minor only, so RDS applies the current patch release rather than
  # pinning the stack to a version that will eventually be deprecated.
  engine_version             = var.db_engine_version
  auto_minor_version_upgrade = true

  # Required before RDS will accept a change of major version. Left on, because
  # db_engine_version is the deliberate control: a major upgrade only happens
  # when that variable changes, and this flag just stops RDS from refusing it.
  allow_major_version_upgrade = true
  instance_class              = var.db_instance_class

  # Refuse Extended Support rather than drift onto it silently.
  #
  # A version past its RDS end of standard support is auto-enrolled and billed
  # per vCPU-hour: measured on this account, $0.118/vCPU-hr, which on a two-vCPU
  # db.t4g.micro is $172/month against the instance's own $12.41. The first warning
  # is the bill, because nothing about the database looks any different.
  #
  # The trade is real: with Extended Support off, AWS performs the major version
  # upgrade itself during a maintenance window once support ends, instead of
  # charging to leave the old version running. For low-traffic sites that is the
  # better failure mode.
  #
  # This only takes effect at creation. RDS accepts EngineLifecycleSupport on
  # create and on restore-from-snapshot, and has no modify equivalent - the
  # setting on an instance that already exists cannot be changed at all. So it
  # is ignored after creation, and the real protection for a running database
  # is db_engine_version: upgrade before the deadline rather than after.
  engine_lifecycle_support = "open-source-rds-extended-support-disabled"

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  username = "wpadmin"
  # RDS creates the master secret in Secrets Manager and owns its rotation, so
  # no password is ever written to Terraform state.
  manage_master_user_password = true

  # No db_name. Databases are created per domain by the instance bootstrap,
  # so the set of sites is not baked into the database at creation time.

  db_subnet_group_name   = aws_db_subnet_group.websites.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.websites.name
  publicly_accessible    = false

  # Single-AZ for the Stateless stage. The Resilient stage flips this to true,
  # which is an in-place modify with a brief failover and no data migration.
  multi_az = false

  # Same zone as the instance and the file system, which is worth pinning rather
  # than leaving to chance: RDS picks any zone in the subnet group, and one that
  # lands in the other zone pays cross-AZ transfer on every query - $0.01/GB each
  # way, about $0.55/month on the stack this one replaced. Changing it later
  # replaces the database, so it is set now while it already matches.
  #
  # Must be dropped when multi_az becomes true: RDS rejects both together.
  availability_zone = aws_subnet.data_a.availability_zone

  apply_immediately       = var.db_apply_immediately
  backup_retention_period = var.db_backup_retention_days
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot   = true

  # Performance Insights is not offered on db.t4g.micro or db.t4g.small. It becomes
  # available if the instance class is raised to db.t4g.medium or larger.
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${var.stack_name}-mysql-final"

  # Create from a snapshot instead of empty. This is how a replacement stack takes
  # over an existing database: per-site users and passwords live inside it, so they
  # arrive intact and each site's wp-config.php only needs its DB_HOST changed.
  #
  # Create-only, so it is ignored afterwards; clearing the variable later must not
  # read as "replace this database with an empty one".
  snapshot_identifier = var.db_snapshot_identifier

  tags = {
    Name       = "WebsitesDatabase"
    CostCenter = "Bugfloyd/Websites/Database"
  }

  lifecycle {
    ignore_changes = [engine_lifecycle_support, snapshot_identifier]
  }
}

output "db_endpoint" {
  description = "RDS endpoint the instances connect to"
  value       = aws_db_instance.websites.address
}

output "db_master_secret_arn" {
  description = "Secrets Manager secret holding the RDS master credentials"
  value       = aws_db_instance.websites.master_user_secret[0].secret_arn
}
