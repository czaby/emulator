# Copied into terraform/ as emulator_override.tf by the CI apply job
# (and by local emulator runs). Not present when the same code is applied
# against real AWS. Terraform merges this provider block into the one in
# providers.tf: top-level arguments here replace same-named arguments,
# and the endpoints nested block is added as a whole.
#
# The aws_endpoint and insecure_skip_tls_verify variables are declared in
# terraform/variables.tf (override files cannot introduce new variables)
# and are unused unless this file is copied in.
# See https://developer.hashicorp.com/terraform/language/files/override

provider "aws" {
  # Stop the provider from calling live AWS STS or the EC2 metadata service.
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

  # The emulator is a single HTTPS endpoint for every service. Listing
  # each service used in this demo keeps the provider from falling back
  # to real AWS if AWS_ENDPOINT_URL is unset.
  endpoints {
    cloudwatch     = var.aws_endpoint
    ec2            = var.aws_endpoint
    ecs            = var.aws_endpoint
    iam            = var.aws_endpoint
    kms            = var.aws_endpoint
    logs           = var.aws_endpoint
    rds            = var.aws_endpoint
    secretsmanager = var.aws_endpoint
    sns            = var.aws_endpoint
    sqs            = var.aws_endpoint
    s3             = var.aws_endpoint
    sts            = var.aws_endpoint
  }
}
