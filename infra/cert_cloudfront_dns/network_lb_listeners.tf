resource "aws_acm_certificate" "lb_certificate" {
  domain_name               = var.domain
  validation_method         = "DNS"
  subject_alternative_names = ["www.${var.domain}"]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name       = "WebsitesLoadBalancerCertificate"
    CostCenter = "Bugfloyd/Websites/Network"
  }
}

resource "aws_acm_certificate_validation" "lb_cert_validation" {
  certificate_arn         = aws_acm_certificate.lb_certificate.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn] # Use the validation records for CloudFront ACM Certificate as they are the same
}

# Listener for HTTPS (Port 443) - Returns "Access Denied" by default
resource "aws_lb_listener" "lb_listener_websites" {
  load_balancer_arn = var.load_balancer_arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.lb_cert_validation.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Access denied"
      status_code  = "403"
    }
  }

  tags = {
    Name       = "WebsitesLoadBalancerListenerWebsites"
    CostCenter = "Bugfloyd/Websites/Network"
  }
}

# Listener for HTTPS (Port 7080) - forwards to Target Group OLS
resource "aws_lb_listener" "lb_listener_ols_admin" {
  load_balancer_arn = var.load_balancer_arn
  port              = 7080
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.lb_cert_validation.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = var.lb_ols_admin_tg_arn
  }

  tags = {
    Name       = "WebsitesLoadBalancerListenerOlsAdmin"
    CostCenter = "Bugfloyd/Websites/Network"
  }
}

# Redirect "www.domain.com" to "domain.com"
resource "aws_lb_listener_rule" "www_redirect_rule" {
  listener_arn = aws_lb_listener.lb_listener_websites.arn
  priority     = 1

  condition {
    host_header {
      values = ["www.${var.domain}"]
    }
  }

  action {
    type = "redirect"

    redirect {
      host        = var.domain
      status_code = "HTTP_301"
    }
  }

  tags = {
    Name       = "WebsitesLoadBalancerListenerRuleWwwRedirect"
    CostCenter = "Bugfloyd/Websites/Network"
  }
}

# Forward requests with a specific HTTP header to Target Group
resource "aws_lb_listener_rule" "lb_listener_rule" {
  listener_arn = aws_lb_listener.lb_listener_websites.arn
  priority     = 2

  condition {
    http_header {
      http_header_name = "X-CloudFront-Auth"
      values           = [random_uuid.unique_id.result]
    }
  }

  action {
    type             = "forward"
    target_group_arn = var.lb_websites_tg_arn
  }

  tags = {
    Name       = "WebsitesLoadBalancerListenerRule"
    CostCenter = "Bugfloyd/Websites/Network"
  }
}