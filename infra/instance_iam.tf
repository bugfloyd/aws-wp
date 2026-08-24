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

resource "aws_iam_instance_profile" "ols_instance_profile" {
  name = "wp_webserver_instance_profile"
  role = aws_iam_role.instance_role.name

  tags = {
    Name       = "WebsitesInstanceIAMProfile"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}


# --- Bootstrap permissions -------------------------------------------------

# Session Manager, so a private instance can be reached without SSH keys.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "bootstrap" {
  name        = "WebsitesInstanceBootstrapPolicy"
  description = "Read the database and WebAdmin credentials needed at instance boot"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDatabaseMasterSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_db_instance.websites.master_user_secret[0].secret_arn]
      },
      {
        # The whole bucket, not just the config prefix: it holds only this
        # stack's own artefacts, and a migration needs somewhere to stage a
        # site archive and a database dump the instance can pull.
        Sid      = "ReadStackArtefacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.config.arn, "${aws_s3_bucket.config.arn}/*"]
      },
      {
        Sid      = "ReadWebAdminPassword"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [aws_ssm_parameter.ols_admin_password.arn]
      },
      {
        # Both values above are encrypted with AWS managed keys. The condition
        # keeps this from becoming a general decrypt grant.
        Sid      = "DecryptThoseTwoOnly"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "kms:ViaService" = [
              "secretsmanager.${var.region}.amazonaws.com",
              "ssm.${var.region}.amazonaws.com",
            ]
          }
        }
      },
    ]
  })

  tags = {
    Name       = "WebsitesInstanceBootstrapPolicy"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

resource "aws_iam_role_policy_attachment" "bootstrap" {
  policy_arn = aws_iam_policy.bootstrap.arn
  role       = aws_iam_role.instance_role.name
}
