data "aws_caller_identity" "current" {}
data "aws_vpc" "mumbai" { default = true }
data "aws_vpc" "hyderabad" {
  provider = aws.hyd
  default  = true
}
data "aws_subnets" "mumbai" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.mumbai.id]
  }
}
data "aws_subnets" "hyderabad" {
  provider = aws.hyd
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.hyderabad.id]
  }
}
data "aws_subnet" "mumbai" {
  for_each = toset(data.aws_subnets.mumbai.ids)
  id       = each.value
}
data "aws_ssm_parameter" "ami_mumbai" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
data "aws_ssm_parameter" "ami_hyd" {
  provider = aws.hyd
  name     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
locals {
  # Two different Mumbai AZs, with deterministic ordering.
  mumbai_subnet_by_az = { for s in data.aws_subnet.mumbai : s.availability_zone => s.id
  }
  mumbai_azs     = slice(sort(keys(local.mumbai_subnet_by_az)), 0, 2)
  mumbai_subnets = [for az in local.mumbai_azs : local.mumbai_subnet_by_az[az]]
  hyd_subnet     = sort(data.aws_subnets.hyderabad.ids)[0]
  namespace      = "${var.prefix}/EC2Recovery"
  names          = ["inst-1", "inst-2"]
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.prefix}-alb-"
  vpc_id      = data.aws_vpc.mumbai.id
  ingress {
    description = "Lab HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.prefix}-alb-sg"
  }
}
resource "aws_security_group" "web" {
  name_prefix = "${var.prefix}-web-"
  vpc_id      = data.aws_vpc.mumbai.id
  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.prefix}-web-sg"
  }
}
resource "aws_security_group" "monitor" {
  provider    = aws.hyd
  name_prefix = "${var.prefix}-monitor-"
  vpc_id      = data.aws_vpc.hyderabad.id
  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.prefix}-monitor-sg"
  }
}

resource "aws_iam_role" "monitor" {
  name_prefix = "${var.prefix}-monitor-"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole"
  }] })
}
resource "aws_iam_policy" "monitor" {
  name_prefix = "${var.prefix}-monitor-"
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "ReadEC2", Effect = "Allow", Action = ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"], Resource = "*" },
    { Sid = "ReadALBTargetHealth", Effect = "Allow", Action = "elasticloadbalancing:DescribeTargetHealth", Resource = "*" },
    { Sid = "StartOnlyWeb", Effect = "Allow", Action = "ec2:StartInstances", Resource = [for i in aws_instance.web : "arn:aws:ec2:ap-south-1:${data.aws_caller_identity.current.account_id}:instance/${i.id}"] },
    { Sid = "PublishAlerts", Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.alerts.arn },
    { Sid = "WriteLabMetric", Effect = "Allow", Action = "cloudwatch:PutMetricData", Resource = "*", Condition = { StringEquals = { "cloudwatch:namespace" = local.namespace } } }
  ] })
}
resource "aws_iam_role_policy_attachment" "monitor" {
  role       = aws_iam_role.monitor.name
  policy_arn = aws_iam_policy.monitor.arn
}
resource "aws_iam_instance_profile" "monitor" {
  name_prefix = "${var.prefix}-monitor-"
  role        = aws_iam_role.monitor.name
}

resource "aws_sns_topic" "alerts" {
  name = "${var.prefix}-alerts"
}
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_instance" "web" {
  count                       = 2
  ami                         = data.aws_ssm_parameter.ami_mumbai.value
  instance_type               = var.web_instance_type
  subnet_id                   = local.mumbai_subnets[count.index]
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = true
  user_data                   = <<-SH
    #!/bin/bash
    set -eux
    dnf install -y httpd
    echo '<h1>${local.names[count.index]}</h1>' > /var/www/html/index.html
    systemctl enable --now httpd
  SH
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tags = { Name = local.names[count.index], RecoveryLab = var.prefix
  }
}
resource "aws_lb_target_group" "web" {
  name_prefix = "rec-"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.mumbai.id
  target_type = "instance"
  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 15
  }
}
resource "aws_lb_target_group_attachment" "web" {
  count            = 2
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web[count.index].id
  port             = 80
}
resource "aws_lb" "web" {
  name_prefix        = "rec-"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.mumbai_subnets
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_instance" "monitor" {
  provider                    = aws.hyd
  ami                         = data.aws_ssm_parameter.ami_hyd.value
  instance_type               = var.monitor_instance_type
  subnet_id                   = local.hyd_subnet
  vpc_security_group_ids      = [aws_security_group.monitor.id]
  associate_public_ip_address = true
  key_name                    = var.key_name_hyd
  iam_instance_profile        = aws_iam_instance_profile.monitor.name
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  user_data = templatefile("${path.module}/monitor_user_data.sh.tftpl", {
    dockerfile_b64   = base64encode(file("${path.module}/Dockerfile"))
    agent_b64        = base64encode(file("${path.module}/agent.py"))
    instance_ids     = join(",", aws_instance.web[*].id)
    target_group_arn = aws_lb_target_group.web.arn
    sns_topic_arn    = aws_sns_topic.alerts.arn
    metric_namespace = local.namespace
  })
  user_data_replace_on_change = true
  depends_on                  = [aws_iam_role_policy_attachment.monitor, aws_lb_target_group_attachment.web, aws_lb_listener.http]
  tags = { Name = "${var.prefix}-monitor", RecoveryLab = var.prefix
  }
}

resource "aws_cloudwatch_dashboard" "recovery" {
  dashboard_name = "${var.prefix}-recovery"
  dashboard_body = jsonencode({ widgets = [
    { type = "metric", x = 0, y = 0, width = 12, height = 6,
      properties = { title = "EC2 stopped in Mumbai (1 = stopping/stopped)", region = "ap-south-1", view = "timeSeries", stacked = false, stat = "Maximum", period = 60,
    metrics = [for i in aws_instance.web : [local.namespace, "EC2Stopped", "InstanceId", i.id]] } },
    { type = "metric", x = 12, y = 0, width = 12, height = 6,
      properties = { title = "ALB healthy hosts in Mumbai", region = "ap-south-1", view = "timeSeries", stat = "Minimum", period = 60,
    metrics = [["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.web.arn_suffix, "LoadBalancer", aws_lb.web.arn_suffix]] } },
    { type = "metric", x = 0, y = 6, width = 24, height = 6,
      properties = { title = "EC2 system status checks", region = "ap-south-1", view = "timeSeries", stat = "Maximum", period = 60,
      metrics = [for i in aws_instance.web : ["AWS/EC2", "StatusCheckFailed", "InstanceId", i.id]] }
    }
  ] })
}
