# Instance bootstrap.
#
# The AMI is a bare OpenLiteSpeed install: no virtual hosts, no domain mapping,
# no WordPress. Everything that makes an instance serve a site is rendered here
# and applied at first boot, so any instance is interchangeable with any other.

resource "random_password" "ols_admin" {
  length  = 32
  special = false
}

# Held in Parameter Store rather than baked into the image, so it can be
# rotated without a rebuild and is identical across instances that are
# identical by design. SecureString is free; Secrets Manager would be $0.40/mo
# for the same thing.
resource "aws_ssm_parameter" "ols_admin_password" {
  name        = "/${var.stack_name}/ols/admin-password"
  description = "OpenLiteSpeed WebAdmin password, applied at instance boot"
  type        = "SecureString"
  value       = random_password.ols_admin.result

  tags = {
    Name       = "WebsitesOlsAdminPassword"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

locals {
  domains_list = keys(var.domains)

  # Rendered once with a placeholder rather than per domain; the bootstrap loop
  # substitutes the real domain for each site it sets up.
  vhost_config = templatefile("${path.module}/templates/vhconf.conf.tftpl", {
    domain = "__DOMAIN__"
  })

  httpd_config = templatefile("${path.module}/templates/httpd_config.conf.tftpl", {
    domains      = local.domains_list
    http_port    = var.webserver_http_port
    enable_cache = var.enable_ols_cache ? 1 : 0
    php_children = var.php_children
  })

  admin_config = file("${path.module}/templates/admin_config.conf.tftpl")

  bootstrap = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    region          = var.region
    efs_dns         = "${aws_efs_file_system.websites.id}.efs.${var.region}.amazonaws.com"
    db_secret_arn   = aws_db_instance.websites.master_user_secret[0].secret_arn
    db_host         = aws_db_instance.websites.address
    ols_admin_param = aws_ssm_parameter.ols_admin_password.name
    http_port       = var.webserver_http_port
    domain_list     = join(" ", [for d in local.domains_list : "\"${d}\""])
    config_bucket   = aws_s3_bucket.config.id
    # Stamped in so a config change produces a new launch template version and
    # therefore a rolling refresh, rather than silently drifting.
    config_revision = md5(join("", [local.httpd_config, local.vhost_config, local.admin_config]))
  })
}

output "ols_admin_password_parameter" {
  description = "Parameter Store name holding the WebAdmin password"
  value       = aws_ssm_parameter.ols_admin_password.name
}
