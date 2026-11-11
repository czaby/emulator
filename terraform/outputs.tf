output "bucket_id" {
  description = "Name of the S3 bucket created in the emulator."
  value       = aws_s3_bucket.demo.id
}

output "table_name" {
  description = "Name of the DynamoDB table created in the emulator."
  value       = aws_dynamodb_table.demo.name
}

output "table_arn" {
  description = "ARN of the DynamoDB table (account 000000000000 in the emulator)."
  value       = aws_dynamodb_table.demo.arn
}

output "aws_endpoint" {
  description = "Endpoint the provider was pointed at."
  value       = var.aws_endpoint
}
