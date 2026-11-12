# Standard AWS provider configuration, usable against real AWS as-is.
# For emulator runs, the CI apply job (and local emulator instructions)
# copy ci/emulator_override.tf into this directory as emulator_override.tf.
# Terraform then merges the extra arguments (endpoints, skip_* flags,
# s3_use_path_style, insecure) into this provider block.
# See https://developer.hashicorp.com/terraform/language/files/override
provider "aws" {
  region = var.aws_region
}
