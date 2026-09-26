# The canary runs as a Lambda function AWS manages on your behalf, so it needs
# a role even though there is no function in this configuration to attach it to.

resource "aws_iam_role" "canary" {
  count = var.enable_canary ? 1 : 0

  name = "${var.stack_name}-canary-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = {
    Name       = "WebsitesCanaryRole"
    CostCenter = "Bugfloyd/Websites/Monitoring"
  }
}

resource "aws_iam_role_policy" "canary" {
  count = var.enable_canary ? 1 : 0

  name = "${var.stack_name}-canary"
  role = aws_iam_role.canary[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteArtifacts"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.cloudfront_logging_bucket.arn}/canary/*"
      },
      {
        Sid      = "ResolveArtifactBucket"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = aws_s3_bucket.cloudfront_logging_bucket.arn
      },
      {
        Sid      = "ListBucketsForArtifactUpload"
        Effect   = "Allow"
        Action   = ["s3:ListAllMyBuckets"]
        Resource = "*"
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:*:log-group:/aws/lambda/cwsyn-*"
      },
      {
        # Scoped by namespace rather than by resource, which is the only
        # dimension PutMetricData supports.
        Sid      = "PublishCanaryMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "CloudWatchSynthetics" }
        }
      }
    ]
  })
}
