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
| Stateless | [`v2-stateless`](../../tree/v2-stateless) | Files move to FSx for OpenZFS, the database to RDS, certificates to ACM behind CloudFront, and media is mirrored to S3. The instance configures itself at boot and holds nothing — destroy it and rebuild and the site is unchanged. Still one instance. | ~$57/mo | _in progress_ |
| Scalable | _planned_ | Private subnets, a NAT gateway, an application load balancer and an Auto Scaling group. One instance becomes many. | ~$125/mo | _planned_ |
| Resilient | _planned_ | Removes the single points of failure: instances across both AZs, a NAT gateway per AZ, RDS Multi-AZ, and a Multi-AZ file system. | ~$225/mo | _planned_ |
| Cached | _planned_ | ElastiCache plus the LiteSpeed Cache plugin. | ~$250/mo | _planned_ |
| Reference | _planned_ | Aurora with a read replica and a CloudWatch dashboard, completing the AWS reference architecture. | ~$335/mo | _planned_ |

Later-stage figures are estimates carried forward from v2's measured cost, not yet built.

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
| [`infra/`](infra/) | Networking, compute, file system, media buckets, database, CloudFront, ACM, backups and alerting. |

Both use an S3 backend with native state locking (`use_lockfile`), configured through a
`backend_config.hcl` that is not committed.

## Shape

```
                  Route 53
                     |
          CloudFront + ACM  -- TLS terminates here
             |           \
             |            \  /wp-content/uploads/*
             |             S3 media bucket   --falls back on 403/404-->  instance
             | everything else, plain HTTP
   +---------v-----------+   public subnet
   | t3.micro + EIP      |   port 80 from CloudFront's prefix list only
   | OpenLiteSpeed/LSPHP |
   +----+----------+-----+
        |          |          data subnets, no route off the VPC
  FSx for OpenZFS  RDS MySQL 8.4
```

One `t3.micro` in a public subnet with an **Elastic IP**, CloudFront and ACM in front. No
load balancer, no NAT gateway, no Auto Scaling group — the instance reaches the internet
through the internet gateway directly, and a security group locked to CloudFront's managed
prefix list is what keeps it unreachable to everyone else.

The Elastic IP is not cosmetic: CloudFront needs an origin that survives the instance being
replaced, and without one the rebuild this stage makes possible would silently point every
distribution at nothing.

**The VPC uses private address space**, `10.20.0.0/16` by default, with its subnets carved
from `vpc_cidr`. A publicly routable range looks harmless until a plugin calls an API hosted
inside it: that traffic is routed locally and never leaves the VPC. The range is fixed for the
life of a VPC, so it is worth getting right before the first apply.

## Storage

Three kinds of state used to live on the instance: **files**, the **database**, and
**certificates**. This stage moves all three off — to FSx for OpenZFS, to RDS, and to ACM
behind CloudFront.

### Files: FSx for OpenZFS

The whole WordPress document root, uploads included, lives on an FSx for OpenZFS file system
mounted at `/var/www` over NFS 4.2.

**Why not EFS.** Both are managed NFS, and the difference is what a single file operation
costs. EFS is serverless and bills per GB with no floor, but every call crosses a shared
distributed service. A WordPress document root is unusually operation-heavy: a plugin update
deletes one directory and unpacks another, file by file.

| | EFS | FSx for OpenZFS |
| --- | --- | --- |
| File creations, measured | 133/sec | ~500/sec |
| 5,872-file WooCommerce install | ~90 s | 39 s |
| Sizing | automatic | provisioned — and it can fill up |
| Cost | $0.30/GB, no floor | **$24.64/month floor**, then $0.099/GB |
| Availability | multi-AZ | Single-AZ here |

**FSx buys speed, not savings.** Its floor is a fixed charge for provisioned capacity, so it
falls per site as sites are added — but EFS has no floor at all, and stays cheaper until total
data passes roughly 82 GB. Single-AZ is acceptable while the instance is itself in one zone;
the Resilient stage needs Multi-AZ, at $75.55/month.

Two things about the mount look removable and are not:

- **No `noresvport`**, which EFS documentation recommends. FSx exports default to `secure`,
  requiring a privileged source port, and asking for the opposite fails with
  `Operation not permitted` — which reads like an export or security-group fault and is
  neither.
- **The root volume is exported at `/fsx`**, not at `/`.

### Media: mirrored to S3, served with a fallback

WordPress is untouched — no offload plugin, no stream wrapper. It keeps writing uploads to
`wp-content/uploads` on the file system, which stays the source of truth. A systemd timer
mirrors each site's uploads to its own S3 bucket every ten minutes, and CloudFront serves
`/wp-content/uploads/*` from an **origin group**: the bucket first, the instance if the bucket
does not have the file yet.

So the sync interval is a performance knob, not a data-loss window. An upload made a minute
ago is served by the instance; once mirrored, it is served by S3 and never reaches the web
tier again.

Details that decide whether this works:

- **The failover criteria must include 403, not only 404.** The bucket policy grants
  CloudFront `s3:GetObject` and not `s3:ListBucket`, so S3 answers a missing key with
  `AccessDenied`. A criteria list of `[404]` reads sensibly and never fails over.
- **CloudFront reaches the instance as `origin.<domain>`**, a per-site record for the Elastic
  IP, and OpenLiteSpeed maps that name to its site. The media path cannot forward the viewer's
  `Host` header, because S3 reads `Host` to choose the bucket — so when it falls back to the
  instance, the origin's own name is the `Host` the instance sees. With a single shared origin
  name, every site's fallback lands on the catch-all virtual host and serves the wrong site. A
  one-site stack cannot show this, because its catch-all is the right site.
- **`sync --delete`, guarded.** Without `--delete`, media deleted in WordPress stays served from
  the edge. With it, an unmounted file system looks like an empty directory and would empty
  the bucket — so the timer refuses to run unless the mount is present.
- **One bucket per site per environment**, named `<stack_name>-<domain>-media`. A staging site
  pointed at a production bucket would delete production media on its first sync.

### Database: RDS

MySQL 8.4 on `db.t4g.micro`, in data subnets with no route off the VPC. RDS owns the master
secret in Secrets Manager; the bootstrap creates one database and user per site.

`db_snapshot_identifier` creates the database from a snapshot instead of empty, which is how
a replacement stack takes over an existing one's data. Per-site users and passwords live in
the database, so they arrive intact.

### Backups

RDS automated backups with 30-day retention, and AWS Backup for the file system on a daily
plan with 30-day retention.

## Sizing

One `t3.micro` — 2 vCPU, 1 GiB, and a 1 GB swapfile. Serving three sites it sits around
420–440 MB of 909 MB with swap untouched. Instance type and worker count are both variables.

**`php_children` is a ceiling, not an allocation.** LSAPI forks workers on demand, so idle
sites cost nothing. But the ceiling has to fit in memory when a burst reaches it, and the
number that matters is the *incremental* cost of a worker, not its RSS: workers fork from a
common parent and share most of their pages. Each adds about **26 MB PSS** while showing
95 MB RSS — so sizing from `ps` overstates the cost roughly threefold.

Budget from the baseline instead: the OS, OpenLiteSpeed and the SSM agent occupy around
450 MB. The swapfile covers the tail — PHP's `memory_limit` is 256 MB, and a handful of
simultaneously heavy requests can each grow far past the average. Raise the instance type
before raising `php_children`.

There is no Auto Scaling group at this stage and no load balancer health check, so nothing
*acts* when the site stops responding. A Synthetics canary covers the noticing; the Scalable
stage adds the acting, by putting a load balancer in front that can replace a failed instance
rather than merely report it.

## How an instance configures itself

The AMI is a bare OpenLiteSpeed install — no virtual host, no domain mapping, no WordPress.
Everything that makes an instance serve a site happens at first boot:

1. Mount the file system at `/var/www`
2. Write PHP settings, and install WP-CLI
3. Read the database credentials from Secrets Manager and the WebAdmin password from
   Parameter Store
4. Fetch the rendered OpenLiteSpeed configuration from S3 and install it
5. Under a lock held on shared storage, create the database and install WordPress for any
   domain that does not have it yet — and **leave alone any site that already has a
   `wp-config.php`**
6. Start the WP-Cron and media-sync timers, and OpenLiteSpeed

Configuration changes go through a rebuild rather than through a console. The rendered
OpenLiteSpeed config lives in S3 and its content hash is stamped into the instance's user
data, so changing it replaces the instance instead of leaving a running box configured by a
script it no longer matches. The bootstrap is gzipped into user data, having passed EC2's
16 KB limit; cloud-init decompresses it.

TLS is terminated at CloudFront with an ACM certificate and the origin is reached over plain
HTTP, so there is no certificate on the instance and nothing to renew.

**PHP settings are a scan-directory drop-in**, not edits to `php.ini`. The image ships PHP's
own defaults — a 2 MB upload cap and a 30-second execution limit, both wrong for WordPress —
and a drop-in sorting last is the only place a value cannot be silently overridden.

**OPcache matters more on a network file system.** Without it every request re-reads PHP
source over NFS. `opcache.revalidate_freq` is 900 rather than 2, because revalidation
`stat()`s every cached file and each one is a round trip. WordPress calls
`opcache_invalidate()` on files it writes during updates, so its own changes apply at once.
**Changes made outside WordPress do not** — editing `wp-config.php` by hand can leave the old
version running for up to fifteen minutes. Restart OpenLiteSpeed after any such edit.

**Large plugin updates through the admin panel** are bounded by CloudFront's origin timeout,
raised to 120 seconds — this account's quota. WP-CLI over Session Manager has no such ceiling:

```sh
wp-site <domain> plugin update <slug>
```

## Naming

Every resource whose name has to be unique somewhere is prefixed with `stack_name`, so a
second stack in the same account is one variable away. What the prefix is worth depends on
how wide that uniqueness scope is:

| Scope | Resources | Collides with |
| ----- | --------- | ------------- |
| The account | IAM roles, policies and instance profiles; CloudFront cache and origin request policies; the origin access control | any stack you own, anywhere |
| The region | RDS instance, subnet and parameter groups; SNS; CloudWatch alarms; AWS Backup vault and plan; the SSM parameter; the EC2 key pair; the canary | any stack in the same region |
| The VPC | security groups | nothing — each stack builds its own VPC |
| Globally | the per-site media buckets (derived); the config and CloudFront log buckets (explicit) | every AWS customer |

Security groups are deliberately left unprefixed: their names are unique per VPC and every
stack brings its own.

**Global bucket names are a lottery for generic words.** `head-bucket` answering 404 does not
mean a name can be created — names another account holds can still come back
`BucketAlreadyExists`. The media buckets embed the domain, which makes them effectively
unique; for the two explicit buckets, a suffix of the account ID is the reliable choice.

**`edge_policy_suffix`** stays separate from `stack_name` because CloudFront policy names are
unique account-wide *and* a stack being replaced keeps its policies until its distributions
are deleted. It is the one name that must differ between two generations of the same stack.

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

So `db_engine_version` is a variable, and databases are created with
`engine_lifecycle_support = "open-source-rds-extended-support-disabled"`. That trade is
deliberate: when support ends, AWS performs the major upgrade itself during a maintenance
window instead of quietly charging to keep the old version running.

**That setting only works at creation** — and a restore from snapshot counts. RDS offers no
way to modify it on an existing database, so Terraform can report the change as applied while
RDS keeps the old value. A database that missed it can be fixed by restoring a snapshot into
a new instance.

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
region = "eu-west-1"
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

Then fill in `infra/terraform.tfvars`: a `stack_name`, the hosted zone IDs from the previous
step, your AMI id, globally unique names for the config and CloudFront log buckets, and the
address alarms should notify. For anything that will serve real traffic, also set
`db_deletion_protection = true` and `db_skip_final_snapshot = false` — the defaults are built
to be torn down. Then deploy:

```sh
cd ../infra
terraform init -backend-config backend_config.hcl
terraform apply
```

**Confirm the SNS subscription** from the email AWS sends, or no alarm reaches anyone.

To tear everything down, `terraform destroy` in `infra/` first, then `hostedzones/`. With
deletion protection on, the database has to be released first.

## Reaching the instance

The instance is publicly routable but not publicly reachable: its security group allows port
80 from CloudFront's managed prefix list only. Two ways in:

```sh
# Session Manager — no inbound rule, no key, and it logs to CloudTrail
aws ssm start-session --target i-xxxx

# run something on it without a shell
aws ssm send-command --instance-ids i-xxxx \
  --document-name AWS-RunShellScript --parameters 'commands=["systemctl is-active lsws"]'
```

Prefer the instance ID to a tag filter: every stack tags its instance `WebserverInstance`, so
while two stacks coexist a tag target reaches both.

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

CloudWatch alarms cover EC2 status checks, RDS free storage, and the file system's storage
and throughput. They publish to an SNS topic with an email subscription set by `alert_email`.

**FSx storage can fill up**, which EFS never could, so it has an alarm — computed with metric
math. OpenZFS publishes `StorageCapacity` and `UsedStorageCapacity` in bytes and no percentage;
the obvious-looking `StorageCapacityUtilization` does not exist for it, and an alarm on a metric
that never reports sits in OK forever.

**Every instance replacement raises a brief false alarm.** A new instance takes about five
minutes to start publishing status-check metrics, and the alarm treats missing data as
failing — deliberately, since a dead instance also stops publishing.

Those alarms watch infrastructure, and none of them catches the failure that actually
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

Hourly is the default because five-minute checks cost disproportionately for quiet sites.
What you give up is resolution: an outage shorter than an hour can fall entirely between two
runs, so the canary catches a site that is broken and staying broken.

**The alarm's period is derived from this expression, not set separately.** With a
five-minute period and an hourly canary, eleven windows in twelve contain no data, and
because missing data counts as breaching, the alarm would sit permanently in ALARM.

Set `enable_canary = false` to drop it entirely.

> [!IMPORTANT]
> AWS emails a confirmation link when the subscription is created, and Terraform cannot
> accept it for you. Until you click it the subscription stays in `PendingConfirmation` and
> **no alarm reaches anyone** — without failing the apply or showing an error. A subscription
> can also disappear later with no error either; check `list-subscriptions-by-topic` after any
> change to the topic.
