provider "aws" {
  region = var.aws_region

  # The emulator is a single local account (000000000000). These skips stop
  # the provider from calling live AWS STS or the EC2 metadata service.
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true

  # Required: the emulator endpoint is a host:port, not a virtual-hosted
  # S3 URL. AWS docs also say the emulator does not accept requests that
  # put the bucket name in the host name.
  s3_use_path_style = true

  # Locally, leave this false and set AWS_CA_BUNDLE to the generated ca.pem.
  # In GitLab CI this is set true (see variable description).
  insecure = var.insecure_skip_tls_verify

  endpoints {
    dynamodb = var.aws_endpoint
    s3       = var.aws_endpoint
    sts      = var.aws_endpoint
  }
}
