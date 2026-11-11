terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }

  # Local state is enough here: the emulator keeps resources in memory and
  # discards them when it stops, so there is no remote backend to talk to.
  backend "local" {}
}
