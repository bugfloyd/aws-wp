# WordPress on AWS

Terraform configurations for hosting WordPress on AWS with OpenLiteSpeed, built as a
progression: it starts from the cheapest setup that works and grows, one stage at a time,
toward the
[AWS WordPress reference architecture](https://docs.aws.amazon.com/whitepapers/latest/best-practices-wordpress/reference-architecture.html).

Each stage is a git tag with a companion blog post. Check out the tag that matches the post
you are reading — `main` is always the newest stage and will not match earlier posts.

## Stages

| Stage | Tag | What it adds | Rough cost | Post |
| ----- | --- | ------------ | ---------- | ---- |
| Minimal | [`v1-minimal`](../../tree/v1-minimal) | One EC2 instance in a public subnet, Route 53 A-records straight to its IP, LiteSpeed Marketplace AMI. No load balancer, no CDN. | ~$25/mo | [Beginners Guide: The Most Minimal & Cost-Effective Setup](https://bugfloyd.com/beginners-guide-minimal-wordpress-hosting-aws-terraform-openlitespeed) |
| Scalable | _in progress on `main`_ | CloudFront, ALB, auto-scaling group in private subnets, NAT gateway, EC2 Instance Connect endpoint. Shared storage (EFS) and a managed database (RDS) to make the instances stateless. | ~$115/mo | _planned_ |
| Reference | _planned_ | Aurora with a read replica, ElastiCache for Memcached, W3 Total Cache, S3 origin for static assets, NAT gateway per AZ. | — | _planned_ |

> [!NOTE]
> `main` is mid-stage and **not deployable as-is**. The auto-scaling group launches instances
> that each run their own local MariaDB and their own copy of `/var/www`, so more than one
> instance serves inconsistent content. EFS and RDS are the work in progress that fixes this.
> For a setup you can deploy today, use [`v1-minimal`](../../tree/v1-minimal).

## Layout

| Directory | Description |
| --------- | ----------- |
| [`hostedzones/`](hostedzones/) | Route 53 hosted zones. Deployed separately so domain records outlive the infrastructure. |
| [`infra/`](infra/) | Networking, compute, load balancing, CloudFront, ACM and backups. |

Both use an S3 backend with native state locking (`use_lockfile`), configured through a
`backend_config.hcl` that is not committed.

## Related projects

- [bugfloyd/aws-ols-mariadb-ami](https://github.com/bugfloyd/aws-ols-mariadb-ami) — Packer +
  Ansible build for the OpenLiteSpeed / MariaDB AMI this project launches from the Scalable
  stage onward. Set its output as `ols_image_id`.
- [bugfloyd/ols-wp-backup](https://github.com/bugfloyd/ols-wp-backup) — the server-level
  backup and restore scripts baked into that AMI. `infra/configure-backups.sh` supplies their
  configuration through instance user data at boot.

## Prerequisites

- An AWS account and the AWS CLI configured
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.10
- A registered domain you can point at Route 53

## Deploying

Set your AWS profile:

```sh
export AWS_PROFILE=<AWS_PROFILE>
```

Create `backend_config.hcl` in both directories, pointing at an S3 bucket you own:

```hcl
region = "eu-west-2"
bucket = "your-terraform-state-bucket"
```

Deploy the hosted zones first, then update your registrar with the name servers Terraform
outputs and wait for propagation:

```sh
cd hostedzones
terraform init -backend-config backend_config.hcl
terraform apply
terraform output hosted_zone_name_servers
```

Then deploy the main infrastructure, passing the hosted zone IDs from the previous step into
`domains` in `infra/terraform.tfvars`:

```sh
cd ../infra
terraform init -backend-config backend_config.hcl
terraform apply
```

To tear everything down, `terraform destroy` in `infra/` first, then `hostedzones/`.
