output "alb_url" { value = "http://${aws_lb.web.dns_name}" }
output "web_instance_ids" { value = aws_instance.web[*].id }
output "monitor_public_ip" { value = aws_instance.monitor.public_ip }
output "sns_topic_arn" { value = aws_sns_topic.alerts.arn }
output "dashboard_name" { value = aws_cloudwatch_dashboard.recovery.dashboard_name }
output "dashboard_url" { value = "https://console.aws.amazon.com/cloudwatch/home?region=ap-south-1#dashboards:name=${aws_cloudwatch_dashboard.recovery.dashboard_name}" }
