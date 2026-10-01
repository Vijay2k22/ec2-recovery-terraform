terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
}
provider "aws" {
  region = "ap-south-1"
}
provider "aws" {
  alias  = "hyd"
  region = "ap-south-2"
}
