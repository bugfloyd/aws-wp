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
*acts* when the site stops responding — an EC2 status-check alarm catches the instance dying,
not OpenLiteSpeed breaking while the instance is fine. A Synthetics canary covers the
noticing; the Scalable stage adds the acting, by putting a load balancer in front that can
replace a failed instance rather than merely report it.

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

## Versions

Terraform, the AWS provider and the managed-service engines all track the current stable
release rather than whatever worked when this was written. Currently: **AWS provider 6.x**,
MySQL **8.4**, Synthetics runtime **syn-nodejs-puppeteer-17.0**.

The Terraform floor stays at **1.10** deliberately — that is the release that added
`use_lockfile`, the S3 backend's native state locking, which this project relies on instead
of the deprecated DynamoDB table.

For RDS, tracking the current version is not cosmetic:

**A database left on a version past its RDS end of standard support is enrolled in Extended
Support automatically, and billed per vCPU-hour.** Measured on this account, that is
$0.118/vCPU-hour — **$172/month on a two-vCPU `db.t4g.micro` whose own instance cost is
$13**. Nothing about the database looks different; the first sign is the bill.

So `db_engine_version` is a variable, and new stacks are created with
`engine_lifecycle_support = "open-source-rds-extended-support-disabled"`. That trade is
deliberate: when support ends, AWS performs the major upgrade itself during a maintenance
window instead of quietly charging to keep the old version running. For low-traffic sites,
an upgrade you did not schedule is a better failure than a bill you did not notice.

**That setting only works at creation.** RDS accepts it on create and on
restore-from-snapshot and offers no way to modify it afterwards, so a database that already
exists cannot be opted out — Terraform will report the change as applied and RDS will keep
the old value. On a running database the only real protection is to upgrade
`db_engine_version` before the deadline rather than after.

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

Those four all watch infrastructure, and none of them catches the failure that actually
happens: the web server coming up misconfigured while the machine underneath it is perfectly
healthy. CloudFront makes it worse by continuing to serve the front page from cache, so the
site looks fine from outside while everything dynamic returns 5xx.

A **Synthetics canary** covers that gap — the only check here that makes a request the way a
reader would. It requests `/wp-login.php`, which cannot be served from cache and which only
returns 200 if PHP ran and WordPress reached the database, and it fails the run if the body
comes back without a login form. Its alarm treats missing data as breaching, so a canary that
stops reporting is itself an alert.

Canary runs are billed individually, at $0.0014 each:

| `canary_schedule_expression` | Runs/month | Cost | Worst-case time to alert |
| ---------------------------- | ---------- | ---- | ----------------------- |
| `rate(5 minutes)` | 8,640 | ~$12.10 | ~5 min |
| `rate(15 minutes)` | 2,880 | ~$4.03 | ~15 min |
| `rate(1 hour)` (default) | 730 | ~$1.02 | ~1 hour |

Hourly is the default because five-minute checks would add a third to the cost of the whole
stack, which is the wrong trade for sites this quiet. What you give up is resolution: an
outage shorter than an hour can fall entirely between two runs and never be recorded, so the
canary will not measure brief things like a deploy. It is there to catch a site that is
broken and staying broken.

**The alarm's period is derived from this expression, not set separately.** With a
five-minute period and an hourly canary, eleven windows in twelve contain no data, and
because missing data counts as breaching, the alarm would sit permanently in ALARM. Changing
the schedule alone would quietly break the alerting it exists to drive.

Set `enable_canary = false` to drop it entirely.

> [!IMPORTANT]
> AWS emails a confirmation link when the subscription is created, and Terraform cannot
> accept it for you. Until you click it the subscription stays in `PendingConfirmation` and
> **no alarm reaches anyone** — without failing the apply or showing an error.
