output "iam_bucket_arn" {
  description = "IAM Policy ARN"
  value = aws_iam_policy.partner_data_bucket_policy.arn
}

output "iam_sqs_arn" {
  description = "IAM Policy ARN"
  value = aws_iam_policy.partner_sqs_policy.arn
}

output "iam_dynamodb_arn" {
  description = "IAM Policy ARN"
  value = aws_iam_policy.partner_dynamodb_policy.arn
}

output "function_name" {
  description = "Lambda function name"
  value = aws_lambda_function.partner_lambda.function_name
}

output "cloud_watch_arn" {
  description = "Cloudwatch ARN"
  value = aws_cloudwatch_log_group.partner_cloudwatch.arn
}

