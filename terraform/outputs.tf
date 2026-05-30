output "alb_dns_name" {
  description = "API base URL (use http://this-value)"
  value       = module.compute.alb_dns_name
}
output "cloudfront_domain" { value = module.storage.cloudfront_domain }
output "s3_bucket_name" { value = module.storage.s3_bucket_name }
output "cloudfront_distribution_id" { value = module.storage.cloudfront_distribution_id }
output "ecr_repository_url" { value = module.storage.ecr_repository_url }
output "redis_endpoint" { value = module.compute.redis_endpoint }
