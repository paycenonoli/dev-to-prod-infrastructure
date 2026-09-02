terraform {
  source = "../../../modules/ecr"
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"

  contents = <<EOF
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
EOF
}

inputs = {
  repositories = [
    "frontend",
    "product-service",
    "order-service"
  ]

  image_tag_mutability = "IMMUTABLE"
  scan_on_push         = true

  tags = {
    Project     = "dev-to-prod-promotion"
    ManagedBy   = "terraform"
    Environment = "shared"
  }
}
