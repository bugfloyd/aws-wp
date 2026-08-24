# Target Group for HTTP
resource "aws_lb_target_group" "lb_target_group_websites" {
  name        = "tg-http"
  vpc_id      = aws_vpc.bugfloyd.id
  port        = var.webserver_http_port
  protocol    = "HTTP"
  target_type = "instance"

  # "/" rather than "/wp-login.php": the bootstrap writes a placeholder index
  # before WordPress is installed, so a fresh instance passes immediately
  # instead of being killed mid-provision. The matcher spans redirects because
  # a freshly installed WordPress sends visitors to the setup screen.
  health_check {
    path                = "/"
    port                = "traffic-port"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  tags = {
    Name       = "WebsitesLbTgWebsites"
    CostCenter = "Bugfloyd/Websites/Network"
  }
}
