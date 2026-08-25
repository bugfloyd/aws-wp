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
| Minimal | [`v1-minimal`](../../tree/v1-minimal) | One EC2 instance in a public subnet, Route 53 A-records straight to its IP, Let's Encrypt on the box. | ~$25/mo | [Beginners Guide: The Most Minimal & Cost-Effective Setup](https://bugfloyd.com/beginners-guide-minimal-wordpress-hosting-aws-terraform-openlitespeed) |
| Stateless | [`v2-stateless`](../../tree/v2-stateless) | Files move to EFS, the database to RDS, certificates to ACM behind CloudFront. The instance configures itself at boot and holds nothing — destroy it and rebuild and the site is unchanged. Still one instance. | ~$33/mo | _in progress_ |
| Scalable | _planned_ | Private subnets, a NAT gateway, an application load balancer and an Auto Scaling group. One instance becomes many. | ~$100/mo | _planned_ |
| Resilient | _planned_ | Removes the single points of failure: instances across both AZs, a NAT gateway per AZ, and RDS Multi-AZ. | ~$150/mo | _planned_ |
| Cached | _planned_ | ElastiCache plus the LiteSpeed Cache plugin, and an S3 origin for static assets. | ~$173/mo | _planned_ |
| Reference | _planned_ | Aurora with a read replica and a CloudWatch dashboard, completing the AWS reference architecture. | ~$257/mo | _planned_ |

> [!NOTE]
> **`v2-stateless` runs a single instance, deliberately.** This stage is about removing
> state from the instance, not about running several of them — so it keeps the previous
> stage's shape and changes only where files, the database and certificates live. That makes
> the diff between the two posts exactly the thing being taught. The Scalable stage adds a
> load balancer and an Auto Scaling group.

## Layout

| Directory | Description |
| --------- | ----------- |
| [`hostedzones/`](hostedzones/) | Route 53 hosted zones. Deployed separately so domain records outlive the infrastructure. |
| [`infra/`](infra/) | Networking, compute, storage, database, load balancing, CloudFront, ACM and backups. |

Both use an S3 backend with native state locking (`use_lockfile`), configured through a
`backend_config.hcl` that is not committed.

## Shape

One `t3.micro` in a public subnet with an **Elastic IP**, CloudFront and ACM in front. No
load balancer, no NAT gateway, no Auto Scaling group — the instance reaches the internet
through the internet gateway directly, and a security group locked to CloudFront's managed
prefix list is what keeps it unreachable to everyone else.

The Elastic IP is not cosmetic: CloudFront needs an origin hostname that survives the
instance being replaced, and without one the rebuild this stage makes possible would
silently point every distribution at nothing.

## Sizing

One `t3.micro` — 2 vCPU, 1 GiB. With `php_children = 15` a running instance sits around
330 MB of 909 MB, so there is comfortable headroom for four low-traffic sites. Instance type
and worker count are both variables.

**`php_children` is a ceiling, not an allocation.** LSAPI forks workers on demand, so idle
sites cost nothing. But the ceiling has to fit in memory when a burst reaches it, and the
number that matters is the *incremental* cost of a worker, not its RSS: workers fork from a
common parent and share most of their pages. Measured on a live three-site box, each worker
adds about **26 MB PSS** while showing 95 MB RSS — so sizing from `ps` overstates the cost
by roughly a factor of three.

Budget instead from the baseline: the OS, OpenLiteSpeed and the SSM agent occupy around
450 MB, which leaves about 500 MB of a `t3.micro` for workers. What that does not cover is
the tail — PHP's `memory_limit` is 128 MB, so a handful of simultaneously heavy requests can
each grow far past the average, and there is no swap. Raise the instance type before raising
this.

There is no Auto Scaling group at this stage and no load balancer health check, so nothing
watches whether the site is actually responding — an EC2 status-check alarm catches the
instance dying, not OpenLiteSpeed breaking while the instance is fine. The Scalable stage
fixes both by putting a load balancer in front.

## Naming

Every resource whose name has to be unique somewhere is prefixed with `stack_name`
(default `websites`), so a second stack in the same account is one variable away rather
than a scavenger hunt. What the prefix is worth depends entirely on how wide that
uniqueness scope is:

| Scope | Resources | Collides with |
| ----- | --------- | ------------- |
| The account | IAM roles, policies and instance profiles; CloudFront cache and origin request policies | any stack you own, anywhere |
| The region | RDS instance, subnet and parameter groups; EFS; SNS; CloudWatch alarms; AWS Backup vault and plan; the SSM parameter; the EC2 key pair | any stack in the same region |
| The VPC | security groups | nothing — each stack builds its own VPC |
| Globally | the two S3 buckets | every AWS customer, which is why they stay explicit variables |

Security groups are deliberately left unprefixed. Their names are unique per VPC and every
stack brings its own, so a prefix there buys nothing and only makes the rename churn.

Two names resist the scheme and are worth knowing about:

- **The EFS creation token** is an idempotency key, not a label. Reusing one returns the
  existing file system instead of failing, so two stacks sharing a token would silently
  share storage. It is also create-only — changing it destroys the data — so the resource
  ignores changes to it and only new stacks pick up the derived name.
- **`edge_policy_suffix`** stays separate from `stack_name` because CloudFront policy names
  are unique account-wide *and* the stack being replaced keeps its policies until its
  distributions are deleted. That is the one name that must differ between two generations
  of the same stack.

## How an instance configures itself

Three kinds of state used to live on the instance: **files**, the **database**, and
**certificates**. This stage moves all three off — to EFS, to RDS, and to ACM behind
CloudFront. What is left is a machine that can be destroyed and rebuilt without losing
anything, which is what `user_data_replace_on_change` makes routine rather than theoretical.

The AMI is a bare OpenLiteSpeed install — no virtual host, no domain mapping, no WordPress.
Everything that makes an instance serve a site happens at first boot:

1. Mount EFS at `/var/www`
2. Read the database credentials from Secrets Manager and the WebAdmin password from
   Parameter Store
3. Fetch the rendered OpenLiteSpeed configuration from S3 and install it
4. Under a lock held on shared storage, create the database and install WordPress for any
   domain that does not have it yet
5. Start OpenLiteSpeed

Configuration changes go through a rebuild rather than through a console. The rendered
OpenLiteSpeed config lives in S3 and its content hash is stamped into the instance's user
data, so changing it replaces the instance instead of leaving a running box configured by a
script it no longer matches.

TLS is terminated at CloudFront with an ACM certificate and the origin is reached over plain
HTTP, so there is no certificate on the instance and nothing to renew.

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

## Reaching the instance

The instance is publicly routable but not publicly reachable: its security group allows port
80 from CloudFront's managed prefix list only. Two ways in:

```sh
# Session Manager — no inbound rule, no key, and it logs to CloudTrail
aws ssm start-session --target i-xxxx

# run something on it without a shell
aws ssm send-command --targets Key=tag:Name,Values=WebserverInstance \
  --document-name AWS-RunShellScript --parameters 'commands=["systemctl is-active lsws"]'
```

SSH from the addresses in `admin_ips` is kept as a fallback for when the SSM agent itself is
what is broken.

The OpenLiteSpeed console listens on the loopback interface only, so it needs a forward:

```sh
aws ssm start-session --target i-xxxx \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["7080"],"localPortNumber":["7080"]}'
# then https://localhost:7080
```

The password is in Parameter Store at `/<stack_name>/ols/admin-password`. Anything changed
through that console is lost the next time the instance is replaced.

## Alerting

CloudWatch alarms cover EFS burst credits, EFS IO limit, RDS free storage, and EC2 status
checks. They publish to an SNS topic with an email subscription set by `alert_email`.

> [!IMPORTANT]
> AWS emails a confirmation link when the subscription is created, and Terraform cannot
> accept it for you. Until you click it the subscription stays in `PendingConfirmation` and
> **no alarm reaches anyone** — without failing the apply or showing an error.
