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
    domain        = "__DOMAIN__"
    origin_secret = var.enforce_origin_secret ? random_password.origin_secret.result : ""
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
    fsx_dns         = aws_fsx_openzfs_file_system.websites.dns_name
    db_secret_arn   = aws_db_instance.websites.master_user_secret[0].secret_arn
    db_host         = aws_db_instance.websites.address
    ols_admin_param = aws_ssm_parameter.ols_admin_password.name
    http_port       = var.webserver_http_port
    domain_list     = join(" ", [for d in local.domains_list : "\"${d}\""])
    config_bucket   = aws_s3_bucket.config.id
    php_settings    = var.php_settings

    # Only the mirrored sites, so a domain with the edge disabled does not get a
    # sync target it has no bucket policy for.
    media_buckets       = local.media_bucket_names
    media_sync_interval = var.media_sync_interval
    # Stamped in so a change to any rendered config changes the user data, and
    # user_data_replace_on_change then replaces the instance rather than leaving
    # it running a configuration it no longer matches.
    #
    # The vhost config carries the origin secret, which would mark this hash -
    # and with it the whole user data - sensitive, hiding every bootstrap change
    # from plans. A hash of a 40-character random secret inside a larger file
    # reveals nothing, so it is declared safe to show.
    config_revision = nonsensitive(md5(sensitive(join("", [local.httpd_config, local.vhost_config, local.admin_config, local.edge_cache_guard]))))
  })
}

output "ols_admin_password_parameter" {
  description = "Parameter Store name holding the WebAdmin password"
  value       = aws_ssm_parameter.ols_admin_password.name
}
