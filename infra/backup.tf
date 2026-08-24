# Backups for the shared file system.
#
# The database is covered by its own RDS automated backups, configured in
# database.tf. This handles the other half of the state: everything on EFS.
#
# This replaces the ols-wp-backup scripts that earlier stages baked into the
# AMI. Those dumped a local MariaDB and zipped /var/www, and neither assumption
# survives moving to RDS and shared storage.

resource "aws_backup_vault" "websites" {
  name = "websites-backup-vault"

  tags = {
    Name       = "WebsitesBackupVault"
    CostCenter = "Bugfloyd/Websites/Storage"
  }
}

resource "aws_backup_plan" "websites" {
  name = "websites-daily"

  rule {
    rule_name         = "daily-retain-30-days"
    target_vault_name = aws_backup_vault.websites.name

    # 03:00 UTC, after the 02:00-03:00 RDS backup window so the two do not
    # contend for the same quiet period.
    schedule = "cron(0 3 * * ? *)"

    # Minutes. If the job cannot start within an hour, skip it rather than
    # letting it drift into the working day.
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = 30
    }

    recovery_point_tags = {
      Name       = "WebsitesEfsRecoveryPoint"
      CostCenter = "Bugfloyd/Websites/Storage"
    }
  }

  tags = {
    Name       = "WebsitesBackupPlan"
    CostCenter = "Bugfloyd/Websites/Storage"
  }
}

resource "aws_iam_role" "backup" {
  name = "websites_backup_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name       = "WebsitesBackupRole"
    CostCenter = "Bugfloyd/Websites/Storage"
  }
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# Attached so the same role can drive a restore. Without it, recovering means
# first working out why the restore job is denied, which is not the moment for
# that discovery.
resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_selection" "efs" {
  name         = "websites-efs"
  plan_id      = aws_backup_plan.websites.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [
    aws_efs_file_system.websites.arn,
  ]
}

output "backup_vault_name" {
  description = "AWS Backup vault holding EFS recovery points"
  value       = aws_backup_vault.websites.name
}
