variable "aws_endpoint" {
  type        = string
  description = "AWS Emulator HTTPS endpoint. Use https://127.0.0.1:9297 locally. In GitLab CI the service hostname is used instead."
  default     = "https://127.0.0.1:9297"
}

variable "insecure_skip_tls_verify" {
  type        = bool
  description = "Skip TLS verification. Leave false locally (trust ca.pem via AWS_CA_BUNDLE). Set true in GitLab CI because the emulator certificate is issued for 127.0.0.1, while the job reaches the service as aws-emulator."
  default     = false
}

variable "aws_region" {
  type        = string
  description = "Region sent in each request. The emulator accepts any Region but does not keep resources separate by Region, so use one value."
  default     = "us-east-1"
}

variable "bucket_name" {
  type        = string
  description = "S3 bucket to create in the emulator."
  default     = "emulator-demo-bucket"
}

variable "table_name" {
  type        = string
  description = "DynamoDB table to create in the emulator."
  default     = "emulator-demo-table"
}
