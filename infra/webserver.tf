resource "aws_key_pair" "websites_key_pair" {
  key_name   = "WebsitesKeyPair"
  public_key = var.admin_public_key

  tags = {
    Name       = "WebsitesInstanceKeyPair"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

# Launch Template
resource "aws_launch_template" "wordpress" {
  name_prefix   = "wordpress-"
  image_id      = var.ols_image_id
  instance_type = var.instance_type
  key_name      = aws_key_pair.websites_key_pair.key_name

  vpc_security_group_ids = [aws_security_group.ec2_web.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ols_instance_profile.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(local.bootstrap)


  tag_specifications {
    resource_type = "instance"
    tags = {
      Name       = "WordPress-AutoScaling"
      CostCenter = "Bugfloyd/Websites/Instance"
    }
  }

  tags = {
    Name       = "WordPressLaunchTemplate"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "wordpress" {
  name = "wordpress-asg"
  # Single AZ for the Stateless stage. Spreading the web tier across two zones
  # while the database and the NAT gateway both sit in one would be theatre:
  # losing that zone takes the site down regardless of where the instances are.
  # The Resilient stage widens this to both private subnets at the same time as
  # it makes the database and egress path multi-AZ.
  vpc_zone_identifier = [aws_subnet.private_a.id]
  target_group_arns   = [aws_lb_target_group.lb_target_group_websites.arn]
  health_check_type   = "ELB"
  # Generous: a cold instance mounts EFS, may install WordPress, and restarts
  # OpenLiteSpeed before it can serve anything. Too short and the group kills
  # instances mid-provision, which never resolves on its own.
  health_check_grace_period = 600

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  launch_template {
    id      = aws_launch_template.wordpress.id
    version = "$Latest"
  }

  # Instance refresh for zero-downtime updates
  # Explicit launch-before-terminate. At a desired capacity of 1, a minimum
  # healthy percentage below 100 permits terminating the only instance first,
  # which is a visible outage on every configuration change. Requiring 100%
  # healthy and allowing 200% gives the group room to bring a replacement into
  # service before retiring the old one - so max_size must be at least
  # desired_capacity + 1 for a refresh to make progress.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
    }
  }

  tag {
    key                 = "Name"
    value               = "WordPress-ASG"
    propagate_at_launch = false
  }

  tag {
    key                 = "CostCenter"
    value               = "Bugfloyd/Websites/Instance"
    propagate_at_launch = true
  }
}

# Auto Scaling Policies
resource "aws_autoscaling_policy" "scale_up" {
  name                   = "wordpress-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.wordpress.name
}

resource "aws_autoscaling_policy" "scale_down" {
  name                   = "wordpress-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.wordpress.name
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "wordpress-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "75"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = [aws_autoscaling_policy.scale_up.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.wordpress.name
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "wordpress-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "25"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = [aws_autoscaling_policy.scale_down.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.wordpress.name
  }
}