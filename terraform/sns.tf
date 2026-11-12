# SNS topic with an SQS subscription. The queue policy is what real AWS
# needs to accept messages from the topic; the emulator does not evaluate IAM.

resource "aws_sns_topic" "demo" {
  name = var.sns_topic_name
}

resource "aws_sqs_queue" "demo" {
  name = var.sqs_queue_name
}

resource "aws_sns_topic_subscription" "sqs" {
  topic_arn = aws_sns_topic.demo.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.demo.arn
}

resource "aws_sqs_queue_policy" "demo" {
  queue_url = aws_sqs_queue.demo.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSNSMessages"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.demo.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_sns_topic.demo.arn
          }
        }
      }
    ]
  })
}
