output "ecr_repository_url"         { value = aws_ecr_repository.backend.repository_url }
output "cloudfront_domain"          { value = aws_cloudfront_distribution.frontend.domain_name }
output "cloudfront_distribution_id" { value = aws_cloudfront_distribution.frontend.id }
output "s3_bucket_name"             { value = aws_s3_bucket.frontend.bucket }
output "s3_bucket_arn"              { value = aws_s3_bucket.frontend.arn }
