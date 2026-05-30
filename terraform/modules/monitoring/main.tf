resource "aws_cloudwatch_log_group" "app" {
  name              = "/starttech/${var.environment}/app"
  retention_in_days = 30
  tags              = { Name = "${var.environment}-app-logs" }
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/starttech/${var.environment}/access"
  retention_in_days = 14
  tags              = { Name = "${var.environment}-access-logs" }
}
