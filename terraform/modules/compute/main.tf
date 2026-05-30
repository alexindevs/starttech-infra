# ── IAM Role for EC2 ─────────────────────────────────────────────────────────
 
resource "aws_iam_role" "ec2" {
  name = "${var.environment}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}
 
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
 
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
 
resource "aws_iam_role_policy" "ecr_pull" {
  name = "${var.environment}-ecr-pull"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken","ecr:BatchCheckLayerAvailability",
                  "ecr:GetDownloadUrlForLayer","ecr:BatchGetImage"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "ssm_secrets" {
  name = "${var.environment}-ssm-secrets"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParametersByPath"
      ]
      Resource = "arn:aws:ssm:*:*:parameter/starttech/${var.environment}/*"
    }]
  })
}
 
resource "aws_iam_instance_profile" "ec2" {
  name = "${var.environment}-ec2-profile"
  role = aws_iam_role.ec2.name
}
 
# ── Launch Template ───────────────────────────────────────────────────────────
 
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
 
resource "aws_launch_template" "backend" {
  name_prefix            = "${var.environment}-backend-"
  image_id               = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [var.ec2_security_group_id]
 
  iam_instance_profile { name = aws_iam_instance_profile.ec2.name }
 
  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    aws_region         = var.aws_region
    ecr_repository_url = var.ecr_repository_url
    log_group_name     = var.cloudwatch_log_group
    environment        = var.environment
  }))
 
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.environment}-backend" }
  }
}

# ── Application Load Balancer ─────────────────────────────────────────────────
 
resource "aws_lb" "main" {
  name               = "${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids
  tags               = { Name = "${var.environment}-alb" }
}
 
resource "aws_lb_target_group" "backend" {
  name     = "${var.environment}-backend-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id
 
  health_check {
    enabled             = true
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = { Name = "${var.environment}-backend-tg" }
}
 
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}
 
# ── Auto Scaling Group ────────────────────────────────────────────────────────
 
resource "aws_autoscaling_group" "backend" {
  name                      = "${var.environment}-backend-asg"
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.desired_capacity
  vpc_zone_identifier       = var.private_subnet_ids
  target_group_arns         = [aws_lb_target_group.backend.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 60
 
  launch_template {
    id      = aws_launch_template.backend.id
    version = "$Latest"
  }
 
  instance_refresh {
    strategy = "Rolling"
    preferences { min_healthy_percentage = 50 }
  }
 
  tag {
    key                 = "Name"
    value               = "${var.environment}-backend"
    propagate_at_launch = true
  }
}
 
resource "aws_autoscaling_policy" "scale_up" {
  name                   = "${var.environment}-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.backend.name
}

resource "aws_autoscaling_policy" "scale_down" {
  name                   = "${var.environment}-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.backend.name
}

# ── CloudWatch Alarms ─────────────────────────────────────────────────────────
# ALB metrics require the ARN suffix (everything after "loadbalancer/"),
# not the full ARN. We derive it here from the resource directly.

locals {
  alb_arn_suffix = aws_lb.main.arn_suffix
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.environment}-cpu-high"
  alarm_description   = "Scale out when CPU > 70% for 10 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 70
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.backend.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_up.arn]
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${var.environment}-cpu-low"
  alarm_description   = "Scale in when CPU < 30% for 20 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 4
  threshold           = 30
  comparison_operator = "LessThanThreshold"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.backend.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_down.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.environment}-alb-5xx-high"
  alarm_description   = "ALB 5xx errors exceed 10 per minute"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.alb_arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${var.environment}-alb-unhealthy-hosts"
  alarm_description   = "One or more ALB target group hosts are unhealthy"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.alb_arn_suffix
  }
}

# ── ElastiCache Redis ─────────────────────────────────────────────────────────
 
resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.environment}-redis-subnet-group"
  subnet_ids = var.private_subnet_ids
}
 
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${var.environment}-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.0"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [var.redis_security_group_id]
  tags                 = { Name = "${var.environment}-redis" }
}
