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
| Minimal | [`v1-minimal`](../../tree/v1-minimal) | One EC2 instance in a public subnet, Route 53 A-records straight to its IP. No load balancer, no CDN, nothing shared. | ~$25/mo | [Beginners Guide: The Most Minimal & Cost-Effective Setup](https://bugfloyd.com/beginners-guide-minimal-wordpress-hosting-aws-terraform-openlitespeed) |
| Stateless | [`v2-stateless`](../../tree/v2-stateless) | EFS for the document root, RDS for the database, and instances that configure themselves at boot. The Auto Scaling group becomes real: any instance can be replaced without losing anything. | ~$117/mo | _in progress_ |
| Resilient | _planned_ | Removes the single points of failure: Auto Scaling group across both AZs, a NAT gateway per AZ, and RDS Multi-AZ. | ~$164/mo | _planned_ |
| Cached | _planned_ | ElastiCache plus the LiteSpeed Cache plugin, and an S3 origin for static assets. | ~$187/mo | _planned_ |
| Reference | _planned_ | Aurora with a read replica and a CloudWatch dashboard, completing the AWS reference architecture. | ~$256/mo | _planned_ |

> [!NOTE]
> **`v2-stateless` is deliberately single-AZ.** The web tier, the database and the NAT
> gateway all live in one Availability Zone. Spreading the instances across two while the
> database and the egress path stayed in one would look like redundancy without being it —
> losing that zone takes the site down either way. The Resilient stage makes all three
> multi-AZ together.
>
> It still runs two instances, because the benefit there is instance-level rather than
> zone-level: EC2 hosts fail and get retired individually, and every configuration change
> goes out as a new image and a rolling refresh, which is seamless with two and an outage
> with one.

## Layout

| Directory | Description |
| --------- | ----------- |
| [`hostedzones/`](hostedzones/) | Route 53 hosted zones. Deployed separately so domain records outlive the infrastructure. |
| [`infra/`](infra/) | Networking, compute, storage, database, load balancing, CloudFront, ACM and backups. |

Both use an S3 backend with native state locking (`use_lockfile`), configured through a
`backend_config.hcl` that is not committed.

## Scaling

The Auto Scaling group runs **1 `t3.micro` instance** in one Availability Zone, with a
ceiling of 2. It scales on CPU: out at 75%, in at 25%, each over two five-minute periods
with a five-minute cooldown. Health is judged by the load balancer, with a ten-minute grace
period so a cold instance can mount storage and install WordPress before it is assessed.
Instance type and all three size bounds are variables.

`max_size` has to stay above `desired_capacity`: a rolling refresh needs room to bring a
replacement into service before retiring the old instance, which is what makes a
configuration change seamless rather than an outage. At a desired capacity of 1, an
*unplanned* instance failure is still a three to four minute outage while a replacement
boots and bootstraps — that is the trade for running one instance, and it is a reasonable
one at low traffic.

**`php_children` is a ceiling, not an allocation.** LSAPI forks workers on demand, so idle
sites cost nothing. But it has to fit in memory when a burst reaches it: on a 1 GiB
instance roughly 300 MB goes to the OS, OpenLiteSpeed and the SSM agent, leaving room for
about fifteen workers at 40–60 MB each. Raise the instance type before raising this.

Two caveats worth knowing before you rely on it. **CPU is a weak signal for WordPress**,
which usually saturates on the database or on IO while CPU stays unremarkable — target
tracking on `RequestCountPerTarget` measures what actually degrades. And **the end-to-end
reaction is around fifteen minutes** once evaluation periods, cooldown and boot time are
added up, so this handles sustained load rather than spikes.

## How an instance configures itself

The AMI is a bare OpenLiteSpeed install — no virtual host, no domain mapping, no WordPress.
Everything that makes an instance serve a site happens at first boot:

1. Mount EFS at `/var/www`
2. Read the database credentials from Secrets Manager and the WebAdmin password from
   Parameter Store
3. Fetch the rendered OpenLiteSpeed configuration from S3 and install it
4. Under a lock held on shared storage, create the database and install WordPress for any
   domain that does not have it yet
5. Start OpenLiteSpeed

Because every instance does this identically, instances are interchangeable. Configuration
changes go through a new launch template version and a rolling refresh rather than through
a console — including changes to the OpenLiteSpeed config, whose content hash is stamped
into the launch template for exactly that reason.

## Related projects

- [bugfloyd/aws-ols-mariadb-ami](https://github.com/bugfloyd/aws-ols-mariadb-ami) — Packer
  and Ansible build for the AMI. Build it with `-var profile=web` for this project; the
  `standalone` profile builds the self-contained image the AMI blog post describes.
- [bugfloyd/ols-wp-backup](https://github.com/bugfloyd/ols-wp-backup) — server-level backup
  scripts, used by the `standalone` AMI profile. From the Stateless stage onward backups are
  handled by RDS automated backups and AWS Backup instead.

## Prerequisites

- An AWS account and the AWS CLI configured
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.10
- A registered domain delegated to Route 53
- An AMI built from `aws-ols-mariadb-ami` with `profile=web`

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

Then fill in `infra/terraform.tfvars` — the hosted zone IDs from the previous step, your AMI
id, globally unique names for the two S3 buckets, and the address alarms should notify — and
deploy:

```sh
cd ../infra
terraform init -backend-config backend_config.hcl
terraform apply
```

To tear everything down, `terraform destroy` in `infra/` first, then `hostedzones/`.

## Reaching a private instance

Nothing is publicly reachable: the instances have no public IPs, there is no bastion, and
the load balancer only serves the site. Use the EC2 Instance Connect endpoint:

```sh
# a shell
aws ec2-instance-connect ssh --instance-id i-xxxx --connection-type eice

# the OpenLiteSpeed console, which listens on the loopback interface only
aws ec2-instance-connect open-tunnel --instance-id i-xxxx --remote-port 22 --local-port 2222 &
ssh -N -L 7080:127.0.0.1:7080 -p 2222 ubuntu@localhost
# then https://localhost:7080
```

The WebAdmin password is in Parameter Store at `/websites/ols/admin-password`. Note that
anything changed through that console is lost at the next instance refresh.

The instances also register with Systems Manager, so `aws ssm start-session` works, and
`aws ssm send-command` can query or act on the whole group at once — which SSH cannot.

## Alerting

CloudWatch alarms cover EFS burst credits, EFS IO limit, RDS free storage, and unhealthy
load balancer targets. They publish to an SNS topic with an email subscription set by
`alert_email`.

> [!IMPORTANT]
> AWS emails a confirmation link when the subscription is created, and Terraform cannot
> accept it for you. Until you click it the subscription stays in `PendingConfirmation` and
> **no alarm reaches anyone** — without failing the apply or showing an error.
