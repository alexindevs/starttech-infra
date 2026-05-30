output "alb_dns_name"    { value = aws_lb.main.dns_name }
output "alb_arn"         { value = aws_lb.main.arn }
output "asg_name"        { value = aws_autoscaling_group.backend.name }
output "redis_endpoint"  { value = aws_elasticache_cluster.redis.cache_nodes[0].address }
