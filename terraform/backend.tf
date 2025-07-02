terraform {
  backend "s3" {
    bucket = "ahmed-terraform-state-bucket"
    key    = "manara/terraform.tfstate"
    region = "us-east-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}