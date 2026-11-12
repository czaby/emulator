# Control-plane resources used in the official AWS Emulator examples:
# CreateBucket (S3) and CreateTable (DynamoDB, PAY_PER_REQUEST).

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

  # The emulator's DescribeTable returns on_demand_throughput with
  # max_*_request_units = -1. A later apply then tries to clear that
  # block and the emulator rejects the empty UpdateTable. Harmless on
  # real AWS, where this computed block is not set this way.
  lifecycle {
    ignore_changes = [on_demand_throughput]
  }
}
