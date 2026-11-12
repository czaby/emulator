output "bucket_id" {
  description = "Name of the S3 bucket."
  value       = aws_s3_bucket.demo.id
}

output "vpc_id" {
  description = "ID of the demo VPC."
  value       = aws_vpc.demo.id
}

output "db_cluster_id" {
  description = "Identifier of the Aurora MySQL cluster."
  value       = aws_rds_cluster.demo.id
}

output "db_cluster_endpoint" {
  description = "Writer endpoint of the Aurora cluster."
  value       = aws_rds_cluster.demo.endpoint
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.demo.arn
}

output "ecs_task_definition_arn" {
  description = "ARN of the Fargate task definition."
  value       = aws_ecs_task_definition.demo.arn
}

output "ecs_service_name" {
  description = "Name of the Fargate service."
  value       = aws_ecs_service.demo.name
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic."
  value       = aws_sns_topic.demo.arn
}

output "sqs_queue_url" {
  description = "URL of the SQS queue subscribed to the SNS topic."
  value       = aws_sqs_queue.demo.url
}
