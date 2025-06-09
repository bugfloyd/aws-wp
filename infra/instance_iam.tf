resource "aws_iam_role" "instance_role" {
  name = "wp_ols_ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name       = "WebsitesInstanceRole"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

resource "aws_iam_policy" "backup_s3_policy" {
  name        = "WpBackupS3Policy"
  description = "Policy for writing backups to S3 without delete access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${aws_s3_bucket.backups_bucket.id}",
          "arn:aws:s3:::${aws_s3_bucket.backups_bucket.id}/*"
        ]
      }
    ]
  })

  tags = {
    Name       = "WebsitesInstancePolicyS3"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

resource "aws_iam_role_policy_attachment" "attach_backup_s3_policy" {
  policy_arn = aws_iam_policy.backup_s3_policy.arn
  role       = aws_iam_role.instance_role.name
}

resource "aws_iam_instance_profile" "ols_instance_profile" {
  name = "wp_webserver_instance_profile"
  role = aws_iam_role.instance_role.name

  tags = {
    Name       = "WebsitesInstanceIAMProfile"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

