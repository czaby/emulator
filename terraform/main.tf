# S3 CreateBucket is one of the operations the official AWS Emulator
# getting-started examples exercise with the AWS CLI.

resource "aws_s3_bucket" "demo" {
  bucket = var.bucket_name
}
