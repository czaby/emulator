# Control-plane resources used in the official AWS Emulator examples:
# CreateBucket (S3) and CreateTable (DynamoDB, PAY_PER_REQUEST).
# Fidelity for Terraform varies by service; these two operations are
# among the ones the getting-started docs exercise with the AWS CLI.

resource "aws_s3_bucket" "demo" {
  bucket = var.bucket_name
}

resource "aws_dynamodb_table" "demo" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}
