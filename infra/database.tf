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

  # No egress, same reasoning as the EFS security group.

  tags = {
    Name       = "WebsitesRdsSecurityGroup"
    CostCenter = "Bugfloyd/Websites/Database"
  }
}

resource "aws_db_subnet_group" "websites" {
  name       = "websites-db-subnet-group"
  subnet_ids = [aws_subnet.data_a.id, aws_subnet.data_b.id]

  # RDS requires subnets in at least two Availability Zones even for a
  # single-AZ instance, which is why the data tier is built as a pair.

  tags = {
    Name       = "WebsitesDbSubnetGroup"
    CostCenter = "Bugfloyd/Websites/Database"
  }
}

resource "aws_db_parameter_group" "websites" {
  name        = "websites-mysql80"
  family      = "mysql8.0"
  description = "WordPress tuning for MySQL 8.0"

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

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name       = "WebsitesDbParameterGroup"
    CostCenter = "Bugfloyd/Websites/Database"
  }
}

resource "aws_db_instance" "websites" {
  identifier = "websites-mysql"

  engine = "mysql"
  # Major.minor only, so RDS applies the current patch release rather than
  # pinning the stack to a version that will eventually be deprecated.
  engine_version             = "8.0"
  auto_minor_version_upgrade = true
  instance_class             = var.db_instance_class

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

  apply_immediately       = var.db_apply_immediately
  backup_retention_period = var.db_backup_retention_days
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot   = true

  # Performance Insights is not offered on db.t4g.micro. It becomes available
  # if the instance class is raised to db.t4g.small or larger.
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "websites-mysql-final"

  tags = {
    Name       = "WebsitesDatabase"
    CostCenter = "Bugfloyd/Websites/Database"
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
