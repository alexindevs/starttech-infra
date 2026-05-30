terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.98.0" }
  }
  backend "s3" {
    bucket  = "starttech-terraform-state-alexin"
    key     = "production/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Environment = var.environment, Project = "StartTech", ManagedBy = "Terraform" }
  }
}

data "aws_caller_identity" "current" {}

module "monitoring" {
  source      = "./modules/monitoring"
  environment = var.environment
}

module "networking" {
  source             = "./modules/networking"
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

module "storage" {
  source      = "./modules/storage"
  environment = var.environment
}

module "compute" {
  source                  = "./modules/compute"
  environment             = var.environment
  aws_region              = var.aws_region
  vpc_id                  = module.networking.vpc_id
  public_subnet_ids       = module.networking.public_subnet_ids
  private_subnet_ids      = module.networking.private_subnet_ids
  alb_security_group_id   = module.networking.alb_security_group_id
  ec2_security_group_id   = module.networking.ec2_security_group_id
  redis_security_group_id = module.networking.redis_security_group_id
  cloudwatch_log_group    = module.monitoring.app_log_group_name
  ecr_repository_url      = module.storage.ecr_repository_url
  instance_type           = var.instance_type
  min_size                = var.min_size
  max_size                = var.max_size
  desired_capacity        = var.desired_capacity
}
