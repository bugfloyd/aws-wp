# Target Group for HTTP
resource "aws_lb_target_group" "lb_target_group_websites" {
  name        = "tg-http"
  vpc_id      = aws_vpc.bugfloyd.id
  port        = var.webserver_http_port
  protocol    = "HTTP"
  target_type = "instance"

  health_check {
    path                = "/wp-login.php"
    port                = "traffic-port"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name       = "WebsitesLbTgWebsites"
    CostCenter = "Bugfloyd/Websites/Network"
  }
}

# Target Group for HTTPS (Port 7080)
resource "aws_lb_target_group" "lb_target_group_ols_admin" {
  name        = "tg-ols"
  vpc_id      = aws_vpc.bugfloyd.id
  port        = 7080
  protocol    = "HTTPS"
  target_type = "instance"

  health_check {
    path                = "/"
    port                = "traffic-port"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name       = "WebsitesLbTgOlsAdmin"
    CostCenter = "Bugfloyd/Websites/Network"
  }
}

# Register EC2 Instance to Target Groups
# resource "aws_lb_target_group_attachment" "tg_websites_http_attachment" {
#   target_group_arn = aws_lb_target_group.lb_target_group_websites.arn
#   target_id        = aws_instance.webserver.id
# }
#
# resource "aws_lb_target_group_attachment" "tg_ols_admin_https_attachment" {
#   target_group_arn = aws_lb_target_group.lb_target_group_ols_admin.arn
#   target_id        = aws_instance.webserver.id
# }
