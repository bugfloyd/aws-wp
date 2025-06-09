# WordPress on AWS - Minimal Terraform Setup

This project provides Terraform configurations for deploying a minimal but functional WordPress hosting environment on AWS using OpenLiteSpeed. The setup is cost-effective (around $25/month) while providing excellent performance for small to medium WordPress websites.

## Detailed Documentation

For a complete step-by-step guide on how this setup works, including architecture explanations and detailed configuration breakdowns, visit my blog post:  
[Beginners Guide: Hosting WordPress on AWS with OpenLiteSpeed Using Terraform – The Most Minimal & Cost-Effective Setup](https://bugfloyd.com/beginners-guide-minimal-wordpress-hosting-aws-terraform-openlitespeed)

## Features

- **Complete AWS infrastructure** using Terraform for Infrastructure as Code
- **OpenLiteSpeed web server** for high-performance WordPress hosting
- **Multi-domain support** to host multiple WordPress sites on one instance
- **Route 53 integration** for DNS management
- **Security group configurations** to restrict access to admin interfaces
- **Isolated VPC networking** for better security

## Prerequisites

- AWS account with necessary permissions
- Terraform installed ([Download Terraform](https://developer.hashicorp.com/terraform/downloads))
- AWS CLI installed and configured
- Domain name(s) registered and ready to use with AWS Route 53

## Variables

This project uses the following variables, defined in `terraform.tfvars` files:

### Hosted Zones Variables

| Variable   | Description                                      |
| ---------- | ------------------------------------------------ |
| `websites` | List of domains for which to create hosted zones |

Example `hostedzones/terraform.tfvars` file:

```hcl
websites = [
  "example.com",
  "mysite.org"
]
```

### Main Infrastructure Variables

| Variable           | Description                                |
| ------------------ | ------------------------------------------ |
| `region`           | AWS region for deployment                  |
| `ols_image_id`     | OpenLiteSpeed AMI ID to use                |
| `admin_ips`        | Admin IP addresses for secure access       |
| `admin_public_key` | Public SSH key for EC2 access              |
| `domains`          | Map of domains to Route 53 hosted zone IDs |

Example infra/terraform.tfvars file:

```hcl
region           = "eu-central-1"
ols_image_id     = "ami-06132404beb88b9d2"
admin_ips        = ["203.0.113.1/32"]
admin_public_key = "ssh-rsa AAAA..."
domains = {
  "example.com" = "Z1234567890ABC"
}
```

## Deployment Steps

### 1. Create S3 Bucket for Terraform State

```sh
aws s3 mb s3://your-terraform-state-bucket --region eu-central-1
aws s3api put-bucket-versioning --bucket your-terraform-state-bucket --versioning-configuration Status=Enabled --region eu-central-1
```

### 2. Deploy Hosted Zones

```sh
cd hostedzones
terraform init -backend-config backend_config.hcl
terraform plan -out zones.tfplan
terraform apply zones.tfplan
```

### 3. Configure Domain Name Servers

Update your domain's name servers at your registrar using the outputs from the hosted zones deployment.

### 4. Deploy Main Infrastructure

```sh
cd ../infra
terraform init -backend-config backend_config.hcl
terraform plan -out main.tfplan
terraform apply main.tfplan
```

### 5. Configure WordPress

SSH into your EC2 instance and follow the configuration steps outlined in the blog post.

## AMI Options

You have three options for the EC2 AMI:

1. Use a bare minimum AMI and install everything manually (not recommended)
2. Build a custom AMI using the companion repository
3. Use the pre-built OpenLiteSpeed AMI from AWS Marketplace (simplest option)

## Backup Solutions

Since this setup stores WordPress files and databases on the EC2 instance's local storage, implementing a backup solution is critical:

1. Use WordPress backup plugins like UpdraftPlus or WPvivid
2. Implement server-level backup with my [S3-powered backup solution](https://github.com/bugfloyd/ols-wp-backup)

## Security Considerations

- Admin access to the instance is restricted to specific IP addresses
- SSH and OLS admin console access is protected
- Keep your WordPress installation and plugins updated
- Store sensitive information securely
