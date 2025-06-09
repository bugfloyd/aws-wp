provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Owner   = "Bugfloyd"
      Service = "Bugfloyd/Websites"
    }
  }
}
