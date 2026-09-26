output "distribution_arn" {
  description = "ARN of the distribution, so the media bucket policy can name it"
  value       = aws_cloudfront_distribution.cloudfront.arn
}

output "distribution_id" {
  description = "Distribution id"
  value       = aws_cloudfront_distribution.cloudfront.id
}
