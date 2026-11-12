terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local state keeps this demo self-contained. A production deploy of the
  # same code against AWS would typically switch this to a remote backend.
  backend "local" {}
}
