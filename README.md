# WordPress on AWS

Terraform for hosting WordPress on AWS with OpenLiteSpeed, built as a progression: it starts
from the cheapest setup that works and grows one stage at a time toward the
[AWS WordPress reference architecture](https://docs.aws.amazon.com/whitepapers/latest/best-practices-wordpress/reference-architecture.html).

Each stage is a git tag with a companion blog post. Check out the tag that matches the post you
are reading — `main` is always the newest stage and will not match earlier posts.

This README is the reference for the current stage: what is built, why it is built that way, how
it works, and how to operate, debug and recover it.

## Contents

- [Stages](#stages)
- [Architecture](#architecture)
- [Design decisions](#design-decisions)
- [How it works](#how-it-works)
- [Operating it](#operating-it)
- [Logs](#logs)
- [Alerts](#alerts)
- [Debugging](#debugging)
- [Backups and recovery](#backups-and-recovery)
- [Cost](#cost)
- [Known gaps](#known-gaps)
- [Later stages](#later-stages)
- [Repository layout](#repository-layout)

## Stages

| Stage | Tag | What it adds | Rough cost | Post |
| ----- | --- | ------------ | ---------- | ---- |
| Minimal | [`v1-minimal`](../../tree/v1-minimal) | One EC2 instance in a public subnet, Route 53 A-records straight to its IP, Let's Encrypt on the box. | ~$25/mo | [Beginners Guide: The Most Minimal & Cost-Effective Setup](https://bugfloyd.com/beginners-guide-minimal-wordpress-hosting-aws-terraform-openlitespeed) |
| **Stateless** | [`v2-stateless`](../../tree/v2-stateless) | Files move to FSx for OpenZFS, the database to RDS, certificates to ACM behind CloudFront, and media is served from S3. The instance configures itself at boot and holds nothing — destroy it and rebuild and the site is unchanged. Still one instance. | ~$58/mo | _in progress_ |
| Scalable | _planned_ | Private subnets, a NAT gateway, an application load balancer and an Auto Scaling group. One instance becomes many. | ~$125/mo | _planned_ |
| Resilient | _planned_ | Removes the single points of failure: instances across both AZs, a NAT gateway per AZ, RDS Multi-AZ and a Multi-AZ file system. | ~$225/mo | _planned_ |
| Cached | _planned_ | ElastiCache plus the LiteSpeed Cache plugin. | ~$250/mo | _planned_ |
| Reference | _planned_ | Aurora with a read replica and a CloudWatch dashboard. | ~$335/mo | _planned_ |

Figures for unbuilt stages are estimates carried forward from this stage's measured cost.

> [!NOTE]
> **The Stateless stage runs a single instance, deliberately.** It is about removing state from
> the instance, not about running several of them, so it keeps the previous stage's shape. The
> Scalable stage adds the load balancer and Auto Scaling group.

---

## Architecture

```
                         Route 53  (apex and www alias records per site)
                            |
                 CloudFront + ACM + edge functions       TLS terminates here
                    |                         \
   everything else  |                          \  /wp-content/uploads/20??/*
   Host forwarded   |                           \
                    |                     origin group
                    |                     1. S3 media bucket (per site)
                    |                     2. on 403/404/500/502-504: instance
                    |                            |
                    v   plain HTTP, port 80      v
              origin.<domain>  ->  Elastic IP
   +---------------------------------------------------+   public subnet  10.20.1.0/24
   | EC2 t3.micro, OpenLiteSpeed + LSPHP 8.3           |   port 80 from CloudFront + secret
   | configures itself at boot from user data          |   port 22 from admin_ips
   | timers: wp-cron 1 min, media sync 10 min          | --> S3 media buckets
   +----------------+-------------------+---------------+
                    | NFS 4.2           | MySQL 3306
   +----------------v------+   +--------v-------------+   data subnets   10.20.21.0/24
   | FSx for OpenZFS       |   | RDS MySQL 8.4        |                  10.20.22.0/24
   | /var/www, every site  |   | a database per site  |   no route off the VPC
   +-----------------------+   +----------------------+

   AWS Backup (FSx, daily)      RDS automated backups     CloudWatch alarms -> SNS -> email
   Synthetics canary (hourly)   Secrets Manager (DB)      Parameter Store (WebAdmin)
```

### What serves a request

**Pages and anything dynamic** go through CloudFront's default behavior to the instance. The
viewer's `Host`, every cookie and every query string are forwarded, so OpenLiteSpeed picks the
right site and WordPress sees the request as sent.

Before CloudFront looks in its cache, a viewer request function decides whether the request may
share a cached copy with everyone else:

| Visitor | Pages | Static files and media |
| ------- | ----- | ---------------------- |
| Anonymous | one shared copy per page | shared |
| Logged in, any role | never cached: always from WordPress, admin bar and all | shared |
| Commenter who saved their details | never cached: sees their own comment at once, and their name and email never reach anyone else | shared |
| Visitor who unlocked a password-protected post | never cached | shared |
| Shop customer with a cart or session (WooCommerce, Easy Digital Downloads) | never cached | shared |

*Never cached* means the request gets a cache key no other request will ever have: it is never
answered from the cache, and nothing its response produces is served to anyone else. What marks a
request as personal is a cookie from `cache_bypass_cookie_prefixes` — WordPress's logged-in,
commenter and post-password cookies, and the WooCommerce and Easy Digital Downloads cart and
session cookies. Analytics and consent cookies do not count.

Some paths are never cached at all, whatever the headers or cookies say: `/wp-admin/*`
(`admin-ajax.php` included), every `/wp-*.php` (login, comment posting, signup) and the REST API
(`/wp-json/*`, and `?rest_route=` on any page).

How long the rest is kept is decided at the origin, by a guard that runs before every PHP request:

| Response | CloudFront keeps it | The browser is told |
| -------- | ------------------- | ------------------- |
| Public page, feed, sitemap, `robots.txt`, permanent redirect | 7 minutes, then up to 11 hours more while refreshing, and up to a day while the origin is failing | `no-cache` |
| Anything that sets a cookie | never | `no-store` |
| Logged-in pages, password-protected posts, 404s (WordPress's own `no-cache`) | never | as WordPress says |
| Temporary redirects, errors | never | `no-store` |
| Images, CSS, JavaScript and fonts from the instance | 7 days (OpenLiteSpeed's `max-age=604800`) | the same |
| Year-folder media from S3 | 1 day (AWS managed CachingOptimized) | the same |

**An edit reaches visitors within about 7 minutes.** After the 7 minutes the next visitor gets the
old copy instantly while CloudFront fetches the new one, so on a quiet page it can take one more
visit; logged-in users see changes at once. The same old copy keeps answering while the origin is
failing, which is what keeps cached pages up during an instance replacement. **Browsers never keep
pages themselves** — they are told `no-cache` — so a browser cannot show its own anonymous copy
after its user logs in.

**No cached page is older than 12 hours while the origin is healthy**: 7 minutes fresh plus 11 hours
of `stale-while-revalidate`. WordPress embeds nonces in pages — AJAX actions, forms, "load more"
buttons — and a nonce is only guaranteed valid for 12 hours, so an older copy could hand the first
visitor after a quiet spell a page whose buttons fail. While the origin is failing, `stale-if-error`
still serves a copy up to a day old; broken buttons beat no page.

**Tracking parameters** — `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`,
`gclid`, `fbclid`, `msclkid`, `_gl`, `mc_cid` — are left out of the cache key, so campaign links
share one cached copy. They still reach WordPress on every request that goes to the origin. Every
other query string is part of the key, `?ver=` asset versions included.

**WordPress media** — anything under `/wp-content/uploads/20??/` — goes to an origin group. The
site's S3 bucket answers first; if it does not have the file yet, CloudFront retries the same
request against the instance. A timer copies media into the bucket every ten minutes, so a new
image is served by the instance for a few minutes and by S3 from then on.

**Everything else under `/wp-content/uploads/`** — plugin-generated CSS, fonts, form uploads —
takes the default behavior like any other request, served fresh from the file system.

### Components

| Component | Name | Defined in |
| --------- | ---- | ---------- |
| VPC, one public and two data subnets, internet gateway, route tables | `vpc_cidr` (default `10.20.0.0/16`) | `network_*.tf` |
| Web instance, Elastic IP, key pair, security group | tag `WebserverInstance`, key `<stack_name>-key` | `webserver.tf`, `webserver_network.tf` |
| Instance role, profile and policies | `<stack_name>-ec2-role`, `-instance-profile`, `-bootstrap-policy`, `-media-sync` | `instance_iam.tf`, `media.tf` |
| File system | FSx for OpenZFS, security group `<stack_name>-fsx` | `fsx.tf` |
| Database, subnet group, parameter group | `<stack_name>-mysql`, `-db-subnet-group`, `-mysql84` | `database.tf` |
| Rendered OpenLiteSpeed config | S3 bucket `config_bucket_name`, prefix `ols/` | `config_bucket.tf`, `bootstrap.tf` |
| WebAdmin password | Parameter Store `/<stack_name>/ols/admin-password` | `bootstrap.tf` |
| Media buckets, origin access control | `<stack_name>-<domain, dots as hyphens>-media`, `<stack_name>-media<edge_policy_suffix>` | `media.tf` |
| Certificates, distributions, DNS records | per domain | `cert_cloudfront_dns/` |
| Edge caching rules | functions `<stack_name>-viewer-request` and `-viewer-response`, cache policy `<stack_name>-pages`, origin request policy `<stack_name>-origin` — one of each, shared by every site | `edge_cache.tf`, `templates/viewer_request.js.tftpl`, `templates/viewer_response.js` |
| Origin caching guard | `php/edge-cache.php` in the config bucket, loaded before every PHP request | `edge_cache.tf`, `templates/edge_cache.php.tftpl` |
| Origin secret | `random_password.origin_secret`, sent as `X-Origin-Verify`, checked by a virtual host rewrite rule | `main.tf`, `cert_cloudfront_dns/cloudfront.tf`, `templates/vhconf.conf.tftpl` |
| CloudFront logs and canary artifacts | S3 bucket `cloudfront_logging_bucket_name` | `logging_bucket.tf` |
| Backups | vault `<stack_name>-backup-vault`, plan `<stack_name>-daily`, role `<stack_name>-backup-role` | `backup.tf` |
| Alarms, SNS topic | `<stack_name>-*`, topic `<stack_name>-alerts` | `alerts.tf`, `fsx.tf`, `canary.tf` |
| Synthetics canary | `<stack_name>-origin` | `canary.tf`, `canary_iam.tf` |
| Hosted zones | one per domain | `hostedzones/` (separate state) |

---

## Design decisions

### Shape

**One instance.** The stage is about removing state, not adding capacity. Keeping the previous
stage's shape means the difference between the two is exactly the thing being taught.

**A public subnet and no NAT gateway.** The instance reaches the internet through the internet
gateway directly. A private subnet would need a NAT gateway at roughly $37 a month to solve a
problem this stage does not have.

**An Elastic IP.** CloudFront needs an origin that survives the instance being replaced; without
one, a rebuild points every distribution at nothing.

**Private address space.** The VPC defaults to `10.20.0.0/16`, with subnets carved from
`vpc_cidr`. A publicly routable range — this project once used `20.0.0.0/16`, which belongs to
Microsoft — silently breaks any request to a real address inside it, because the VPC routes it
locally. A VPC's range cannot change without replacing it.

**Data subnets with no route off the VPC.** RDS and the file system only need local traffic. RDS
requires a subnet group spanning two Availability Zones even for a single-AZ instance, which is
why the data subnets come as a pair.

### Edge

**TLS terminates at CloudFront with an ACM certificate** (apex plus `www`, DNS-validated), and the
origin is plain HTTP. Certificates are state: a renewal job on a disposable instance is a failure
waiting to happen, and ACM renews by itself. Minimum TLS 1.2, SNI only, HTTP/2, IPv4 only,
viewers redirected to HTTPS.

**The origin is locked twice: by security group and by a shared secret.** Port 80 accepts only
`com.amazonaws.global.cloudfront.origin-facing`, AWS's managed prefix list — but that list covers
every CloudFront distribution in AWS, not only this stack's, so on its own anyone could point a
distribution of theirs at `origin.<domain>` and serve the sites through it. So each of this stack's
distributions adds an `X-Origin-Verify` header carrying a random 40-character value, and
OpenLiteSpeed answers 403 to any request without it — pages and static files alike. The instance's
own requests over the loopback interface are exempt: wp-cron, the bootstrap's health check, and
debugging on the box. Custom headers belong to the origin, so the media fallback carries it too, and
CloudFront overwrites any copy a viewer sends. The value lives in Terraform state, in each
distribution's configuration, and in the rendered virtual host config in the config bucket; plans
show it as sensitive.

**Caching is decided in four layers**, each covering what the one before cannot. The first and
last are enough for most requests; the middle two exist because WordPress and its plugins do not
reliably say what may be shared.

1. **A viewer request function** marks personal requests (see
   [What serves a request](#what-serves-a-request)). It has to be a function: CloudFront cache
   policies take cookie names literally, with no wildcards, and WordPress suffixes its cookies with a
   per-site hash. Exact names would need a cache policy per site, and an account holds only 20 custom
   cache policies — a ceiling on the number of sites. One function, one cache policy and one origin
   request policy serve every distribution instead. A personal request gets a key no other request
   will have, rather than its session cookie in the key, so nothing personal is reused even if a
   plugin forgets to say `no-cache`.
2. **Paths that are never cached**: `/wp-admin/*`, `/wp-*.php` and `/wp-json/*`, with AWS's managed
   CachingDisabled policy. WordPress already sends `no-cache` from most of them; a plugin that forgets
   cannot turn a dashboard, a login form or an API answer into a shared page. The REST API is never
   cached even for anonymous visitors, because its answers can differ per visitor in ways WordPress
   does not mark, and stale answers break the editors and forms that call it.
3. **An origin guard** — `templates/edge_cache.php.tftpl`, loaded before every PHP request through
   `auto_prepend_file` from outside every document root; not a WordPress plugin. It makes two
   decisions WordPress leaves open. A response that sets a cookie is never cached: CloudFront stores
   `Set-Cookie` with the object and replays it on every hit, which was proven on this stack by a test
   page whose one random cookie went to every visitor after the first. And a public page gets an
   explicit TTL with `stale-while-revalidate` and `stale-if-error`, instead of CloudFront's default.
4. **WordPress's own `no-cache`** for logged-in pages, password-protected posts and 404s, which
   CloudFront honours because the minimum TTL is 0.

A **viewer response function** then rewrites what browsers are told about pages to `no-cache`.
Browsers honour `stale-while-revalidate` too, and a browser showing its own day-old copy — the
anonymous version of a page after logging in — is the kind of mix-up the rest exists to prevent.

**Tracking parameters are excluded from the cache key but still forwarded.** The cache policy
includes every query string except the ten in `cache_ignored_query_strings`; the origin request
policy forwards all of them. Stripping them in the function would have removed them from what
WordPress receives, too.

**`/wp-cron.php` and `/xmlrpc.php` answer 403 at the edge**, wherever they appear in a path and in
any case (`edge_blocked_files`). Cron does not need the public URL: it runs every minute from the
instance itself over loopback, and a public `wp-cron.php` only lets anyone trigger it. XML-RPC is a
common brute-force and amplification target that nothing here uses. **What this breaks:** the
WordPress mobile apps and desktop editors that publish over XML-RPC, Jetpack (which connects over
XML-RPC), and pingbacks and trackbacks from other sites. To use any of them, remove `xmlrpc.php`
from the list.

**So does any path segment starting with a dot**, except `/.well-known/`: `/.env`, `/.git/config`,
`/backup/.aws/credentials`. WordPress never serves such a path, and they are most of what scanners
probe for. Each one used to render a full WordPress 404 on the origin: about 8,000 in five days across
the three sites, arriving in bursts that tied up the PHP pool. `/.well-known/` stays open for the
things that live there, such as `security.txt` and app-association files.

**CloudFront reaches the instance as `origin.<domain>`**, a per-site A record for the Elastic IP,
and OpenLiteSpeed lists that name for its site. The media behavior cannot forward the viewer's
`Host` — S3 reads `Host` to decide which bucket a request is for — so when it falls back to the
instance, the origin's own name is the `Host` the instance receives. With one shared origin name,
every site's fallback lands on the catch-all site. A single-site stack cannot show this.

**Origin read timeout is 120 seconds** rather than the default 30: this account's "Response
timeout per origin" quota, which AWS raises on request. An admin action that rewrites thousands of
files on network storage — a large plugin update — needs the room.

**The origin keeps idle connections longer than CloudFront does**: 75 seconds in OpenLiteSpeed against
CloudFront's 60-second origin keep-alive. The other way round, CloudFront could send a request down a
connection OpenLiteSpeed was closing at its stock 5 seconds. A GET is retried, but a POST — a login, a
comment — returned 502, about twice a day.

**The edge can be switched off.** `enable_edge = false` builds everything except certificates,
distributions and DNS. A CloudFront alternate domain name belongs to one distribution at a time,
account-wide, so a replacement stack is built and verified this way and gets its edge at cutover.

### Storage

**FSx for OpenZFS, not EFS.** A WordPress document root is tens of thousands of small files, and
on network storage every file operation is a round trip. What matters is the cost of one
operation, not throughput.

| | EFS | FSx for OpenZFS |
| --- | --- | --- |
| File creations, measured on this workload | 133/sec | ~500/sec |
| 5,872-file WooCommerce install | ~90 s | 39 s |
| Sizing | automatic | provisioned, and it can fill up |
| Cost | $0.30/GB, no floor | $24.64/month floor, then $0.099/GB |
| Availability | multi-AZ | Single-AZ here |

FSx buys speed, not savings: EFS stays cheaper until total data passes roughly 82 GB. The file
system is `SINGLE_AZ_1` — `SINGLE_AZ_2` starts at 160 MB/s of throughput, well over twice the
cost — with 64 GiB of SSD, 64 MB/s, ZSTD compression and encryption at rest. Multi-AZ is
$75.55/month and belongs to the Resilient stage. FSx's advertised sub-millisecond latency describes
the disk; a metadata operation over NFS measures about 2 ms, which is why OPcache's revalidation
interval matters (see [Instance](#instance)).

**Mounted at `:/fsx` over NFS 4.2, without `noresvport`.** FSx exports the root volume at `/fsx`,
not `/`. Its exports default to `secure`, requiring a privileged source port, and `noresvport` —
which EFS documentation recommends — asks for the opposite; the mount then fails with
`Operation not permitted`, which reads like a permissions fault and is not. The export admits the
VPC's range with `rw`, `crossmnt` and `no_root_squash`, so the bootstrap can set ownership.

**Media is served from S3 with the instance as fallback, and nothing is installed inside
WordPress.** WordPress writes uploads to the file system, which stays the source of truth. This
takes cold media requests off the web tier — a large library is cold at most edge locations most
of the time — and keeps media available while the instance is replaced. Because the instance
answers anything the bucket lacks, the sync interval is a performance knob, never a data-loss
window. Every media file lives in both places: the bucket is a serving copy, so it does not reduce
what the file system stores.

**Only year folders go to S3.** WordPress keeps its own media in `uploads/YYYY/MM/` and never
edits a file in place. Plugins also write under `uploads`, and some regenerate a file under the
same name with a `?ver=` query string to bust caches — Elementor's `elementor/css/post-6.css`, for
one. The media behavior's cache policy (AWS managed CachingOptimized) ignores query strings, and
the bucket would hold a stale copy until the next sync. So the CloudFront path pattern
(`/wp-content/uploads/20??/*`) and the sync filter (`20[0-9][0-9]/*`) match each other and nothing
else; plugin files never reach a bucket. That matters for privacy as much as freshness: plugins keep
things under `uploads` that were never meant for a public bucket — form attachments, protected
downloads, backup dumps. A site with WordPress's "organize uploads into month- and year-based
folders" setting turned off keeps its media at the root of `uploads`, which the instance then
serves: slower, never wrong.

**The failover criteria include 403.** Each bucket's policy grants CloudFront `s3:GetObject` and
not `s3:ListBucket`, and S3 will not confirm to such a caller whether a key exists: a missing
object is `AccessDenied`. A criteria list of `[404]` never fails over. The criteria are
403, 404, 500, 502, 503 and 504.

**One media bucket per site per environment**, named `<stack_name>-<domain>-media` with the
domain's dots as hyphens (`wp-prod-naz-li-media`): private,
SSE-S3, Standard storage class, incomplete multipart uploads aborted after seven days. The instance
writes through its own role, scoped to the media buckets only — there are no access keys anywhere.
One origin access control serves every bucket, and each bucket's policy names the one distribution
allowed to read it. A staging stack pointed at a production bucket would delete production media on
its first sync, which is why the stack name is part of the bucket name.

**Rejected alternatives.** An offload plugin (WP Offload Media and similar) puts behavior inside
every WordPress install, and "remove local copies" breaks anything that reads media back from PHP.
Mounting a bucket (s3fs, rclone, Mountpoint for S3) fails on semantics — S3 has no rename, partial
writes or POSIX locks, all of which WordPress and this stack use — and routes every media miss
through the instance anyway. A self-managed NFS server adds a component to patch and a single point
of failure. EBS attaches to one instance, and Multi-Attach needs a cluster file system. Splitting
the document root across tiers — code on FSx, everything else on EFS — saves nothing once the FSx
floor is paid, and core files are read on every request and rewritten by every core update.

### Database

**RDS MySQL 8.4** on `db.t4g.micro`, gp3, 20 GB autoscaling to 100 GB, encrypted, single-AZ, not
publicly accessible, reachable on 3306 only from the web security group. MySQL rather than MariaDB
so a later move to Aurora is an engine swap. Performance Insights needs `db.t4g.medium` or larger.

**RDS owns the master password** (`manage_master_user_password`): it lives in Secrets Manager, is
rotated by RDS, and never appears in Terraform state. There is no `db_name`: the bootstrap creates
one database and one user per site, so the site list is not baked into the database.

**Parameter group** `<stack_name>-mysql84`: `utf8mb4` and `utf8mb4_unicode_ci`, and
`log_bin_trust_function_creators = 1`. Automated backups enable binary logging, and without that
parameter any plugin creating a stored function fails with ERROR 1419.

**`db_engine_version` is a variable, and Extended Support is refused at creation.** A MySQL version
past its RDS end of standard support is enrolled in Extended Support automatically and billed per
vCPU-hour — measured on this account at $0.118, which is $172 a month on a `db.t4g.micro` whose own
cost is $12.41. `engine_lifecycle_support = "open-source-rds-extended-support-disabled"` makes AWS
upgrade the engine at end of support instead. RDS accepts that setting only at creation or
snapshot restore, so it is ignored afterwards; the real protection on a running database is
upgrading before the deadline.

**Minor versions upgrade automatically** in the maintenance window, Sundays 03:30–04:30 UTC, which
is also when a brief database restart is expected. The file system's weekly maintenance follows at
04:30 (`fsx_weekly_maintenance_start_time`). A Single-AZ file system is unavailable for a few minutes
while it is patched, and PHP requests that touch files wait for it, so the stack has one quiet
maintenance period a week instead of two at times AWS picked. Automated backups run daily in 02:00–03:00 UTC.

**`db_snapshot_identifier` creates the database from a snapshot** rather than empty — how a
replacement stack takes over data, with per-site users and passwords intact. It is ignored once the
database exists.

**The defaults are for stacks built to be torn down.** `db_deletion_protection` defaults to
`false`, `db_skip_final_snapshot` to `true` and `db_apply_immediately` to `true`. Anything serving
real traffic should set the first two the other way.

### Instance

**Immutable configuration.** Nothing is configured by hand. Every virtual host, PHP setting and
timer is rendered from Terraform values at boot, and `user_data_replace_on_change` replaces the
instance when any of it changes, rather than leaving a running box configured by a script it no
longer matches.

**User data is gzipped.** EC2 caps user data at 16 KB and the bootstrap script passed it;
cloud-init decompresses it (17 KB becomes about 7). The OpenLiteSpeed configs live in the config
bucket instead, with a hash of their contents stamped into the user data, so changing a config
still replaces the instance.

**The bootstrap never reinstalls or reconfigures a site that already has a `wp-config.php`**; it
only fixes ownership if it has drifted. That is what lets a migrated or restored site keep its own
credentials and table prefix. It also means a change to the generated config reaches only sites
installed after it; existing sites are edited by hand, followed by an OpenLiteSpeed restart.

**WebAdmin listens on `127.0.0.1:7080` only**, with a password generated by Terraform and held in
Parameter Store. The image ships a password hash nobody knows the plaintext of; the bootstrap
replaces it. Changes made through the console are lost on the next replacement — it exists to
inspect live state.

**PHP cannot reach the instance's AWS credentials.** Any process on the instance can ask the EC2
metadata service for the instance role's temporary keys. The role reads the database master secret,
writes and deletes every media bucket, and reads the config bucket with the origin secret. WordPress
never needs any of that, so an exploited plugin on one site should not get it either.
`wp-imds-guard.service` adds one firewall rule: processes running as `www-data` — OpenLiteSpeed and
PHP — are refused at 169.254.169.254. Everything that uses AWS runs as root and is unaffected: the
bootstrap, the media sync and the SSM agent. Terraform also requires IMDSv2 with a hop limit of 1,
rather than relying on the image.

What it means for WordPress: a plugin that needs AWS, such as one that invalidates CloudFront on
publish, cannot borrow the instance role; it needs narrowly scoped access of its own. What it does not
do: isolate the sites from each other. All of them run as `www-data` in one PHP pool, so a compromised
site can still read the others' `wp-config.php`. Separating them needs a Unix user and PHP pool per
site.

**Session Manager, with SSH as a fallback.** The SSM agent is baked into the image and needs no
inbound rule. SSH on port 22 is open only to `admin_ips`, for when the agent itself is what is
broken.

**The image is deliberately bare.** Built by
[aws-ols-mariadb-ami](https://github.com/bugfloyd/aws-ols-mariadb-ami) with the `web` profile: plain
Ubuntu 24.04, OpenLiteSpeed with LSPHP 8.3, `nfs-common`, the AWS CLI v2, and the MySQL 8.0 client
(`mysql-client-core-8.0` — the MariaDB client cannot authenticate with MySQL 8's
`caching_sha2_password`). No virtual hosts, no WordPress, no database server. The SSM agent comes
from its `.deb` rather than the snap Ubuntu ships, because the image removes `snapd`: snap
auto-refresh would change packages on its own schedule, the opposite of how these instances are
meant to change.

**The instance can read its whole config bucket**, not only the `ols/` prefix. A migration stages
site archives and database dumps there for the instance to pull, and a narrower grant fails
silently under `aws s3 cp --quiet`. Keep nothing in that bucket the web server should not read.

**One PHP pool for the whole server.** A pool per virtual host multiplies workers — and database
connections, which a `db.t4g.micro` caps at about 85 — by the number of sites. `php_children`
(default 15) is a ceiling on concurrent PHP requests, not an allocation: LSAPI forks on demand. Each
worker adds about 26 MB of shared memory, although `ps` reports around 95 MB, so size from the
baseline — roughly 450 MB for the OS, OpenLiteSpeed and the SSM agent — rather than from `ps`. Three
sites run at about 420–440 MB of a `t3.micro`'s 909.

**Up to `php_extra_children` (default 5) spare workers.** After a burst, LSAPI retires surplus idle
workers, and the spares let new ones start while that happens, so a burst clears in seconds. The
memory ceiling is therefore `php_children + php_extra_children`: 20 workers, about 830 MB, still in
RAM. `0` makes 15 a hard ceiling and recovery slower: a 40-request burst took up to 9 seconds instead
of 3 in testing.

**No `LSAPI_AVOID_FORK`**, although OpenLiteSpeed's stock configuration sets it. In that mode LSAPI
keeps every worker idle and allows no spares. After any burst that reached 15 concurrent PHP requests,
workers left holding connections OpenLiteSpeed had stopped using waited out LSAPI's 300-second idle
timer. Meanwhile no new worker could start, and requests waited in 60-second steps, then failed with
503. In production that was a five-minute PHP outage for all three sites, several times a day,
triggered by scanners. The stock configuration with 10 workers jams the same way. The reproduction is
in the PR #1 review notes.

**A 1 GB swapfile**, with `vm.swappiness = 10`. PHP's `memory_limit` is 256 MB, so a few heavy
requests at once can each grow far past the average; swap turns that from an out-of-memory kill
into a slow request.

**`memory_limit` is the per-request cap, not OpenLiteSpeed.** The external application's
`memSoftLimit`/`memHardLimit` set the address-space limit of each PHP worker, and a worker maps about
258 MB before it runs any code, mostly OPcache's shared segment. The earlier 512 MB left a request
about 254 MB: less than `memory_limit`, so raising `php_settings` had no effect, and a large photo
could fail to resize with "Out of memory". They are 2047 MB now, as in OpenLiteSpeed's stock
configuration, and only stop a runaway process.

**PHP settings are a drop-in**, written to the PHP scan directory as `zz-wordpress.ini`, which
sorts last and cannot be overridden by the image's `opcache.ini`. Defaults (`php_settings`):
`memory_limit 256M`, `max_execution_time 300`, `max_input_time 300`, `upload_max_filesize 64M`,
`post_max_size 64M`, `max_input_vars 3000`. The image's own defaults — a 2 MB upload cap and a
30-second limit — reject ordinary photos and large plugin updates.

**OPcache is tuned for a network file system.** Revalidation `stat()`s every cached file, a round
trip each on NFS, so `opcache.revalidate_freq` is 900 seconds rather than 2, with 160 MB of cache
for 20,000 files. WordPress calls `opcache_invalidate()` on files it writes during updates, so its
own changes apply at once. **Files changed any other way — editing `wp-config.php` by hand — can
keep running their old version for up to fifteen minutes.**

**WP-CLI is installed**, with a `wp-site <domain> <args>` wrapper that runs it as the web user. It
has no timeout, which the admin panel does.

### Naming

Every resource whose name must be unique beyond the VPC is prefixed with `stack_name`, so a second
stack in the same account — staging, or a replacement for production — is one variable away.

| Name unique across | Resources | Handled by |
| ------------------ | --------- | ---------- |
| The account | IAM roles, policies, instance profile; CloudFront cache and origin request policies, CloudFront Functions, the origin access control | `stack_name`, plus `edge_policy_suffix` for the CloudFront ones |
| The region | RDS instance, subnet and parameter groups; SNS topic; alarms; backup vault and plan; SSM parameter; key pair; canary | `stack_name` |
| The VPC | security groups | nothing needed — every stack builds its own VPC |
| All of AWS | S3 buckets | media buckets embed the domain; the config and log bucket names are variables |

**`edge_policy_suffix`** exists because a stack being replaced keeps its CloudFront policies until
its distributions are deleted, so two generations of the same stack need different policy names.

**Suffix explicit bucket names with the account ID.** A generic name can answer 404 to
`head-bucket` and still fail creation with `BucketAlreadyExists`.

### Versions

Terraform ≥ 1.10 (the release that added `use_lockfile`, the S3 backend's native locking, used
instead of a DynamoDB table), AWS provider 6.x, MySQL 8.4, Synthetics runtime
`syn-nodejs-puppeteer-17.0`. The runtime is pinned because AWS deprecates runtimes on a schedule.

---

## How it works

### Boot sequence

Everything below runs from `infra/templates/bootstrap.sh.tftpl`, logged to
`/var/log/wp-bootstrap.log`. It is idempotent.

1. **Trim attack surface** — disable `rpcbind`, which `nfs-common` pulls in and NFS 4 does not use;
   install and start `wp-imds-guard.service`, which keeps `www-data` off the metadata service
2. **Swap** — create and enable `/swapfile` (1 GB), set `vm.swappiness = 10`
3. **Mount the file system** at `/var/www` via `/etc/fstab`, retrying for up to five minutes; exit
   with `FATAL` if it never mounts
4. **Credentials** — read the RDS master secret from Secrets Manager and the WebAdmin password from
   Parameter Store
5. **WebAdmin** — write the password hash, fetch `ols/admin_config.conf` from the config bucket
6. **Server configuration** — fetch `ols/httpd_config.conf` and the virtual host template, write
   the PHP drop-in, install the origin caching guard, install WP-CLI and `wp-site`
7. **Per-site setup**, holding `/var/www/.bootstrap.lock` (waits up to ten minutes). For each
   domain: render its virtual host config and create its `html` and `logs` directories. If it has
   a `wp-config.php`, correct ownership only if wrong and move on. Otherwise put up a placeholder
   page, create its database and user, install the latest WordPress, and write `wp-config.php`
8. **WP-Cron** — install the runner and its one-minute timer
9. **Media sync** — install the script, its site-to-bucket map and its timer
10. **Start serving** — full stop of OpenLiteSpeed, clear stale sockets, start, and poll
    `http://127.0.0.1/` for up to 60 seconds

A few details decide whether that works. The stop is a full stop and start, not
`lswsctrl restart`, which is graceful: the old process keeps its listeners, moving the admin
listener to loopback collides with the socket it still holds, and OpenLiteSpeed keeps the old
configuration without saying so. The stale sockets matter because the image starts OpenLiteSpeed
at boot as `nobody`, and the real configuration runs as `www-data`, which cannot lock them.

Step 10 never fails the boot. The log ends `OpenLiteSpeed is answering on port 80` when the first
site answered; without that line, the `curl:` errors before `wp-bootstrap finished` say why.

### On the instance

| Path | What |
| ---- | ---- |
| `/var/www/` | the FSx mount — every site, on shared storage |
| `/var/www/<domain>/html/` | the WordPress install, document root |
| `/var/www/<domain>/logs/` | that site's access and error logs |
| `/var/www/.bootstrap.lock`, `.wp-cron.lock`, `.wp-media-sync.lock` | locks electing a single runner |
| `/usr/local/lsws/conf/httpd_config.conf` | server config, fetched at boot |
| `/usr/local/lsws/conf/vhosts/<domain>/vhconf.conf` | per-site config, rendered at boot |
| `/usr/local/lsws/admin/conf/admin_config.conf` | WebAdmin config |
| `/usr/local/lsws/lsphp83/etc/php/8.3/mods-available/zz-wordpress.ini` | PHP settings |
| `/usr/local/lib/wp-edge/edge-cache.php`, `mods-available/zz-edge-cache.ini` | the origin caching guard, and the `auto_prepend_file` line that loads it |
| `/usr/local/bin/wp`, `/usr/local/bin/wp-site` | WP-CLI and its wrapper |
| `/usr/local/bin/wp-cron-runner.sh`, `wp-media-sync.sh` | the two scheduled jobs |
| `/etc/wp-media-sync.conf` | `domain=bucket`, one per line |
| `/etc/systemd/system/wp-cron.{service,timer}`, `wp-media-sync.{service,timer}` | their units |
| `/etc/systemd/system/wp-imds-guard.service` | the `iptables` rule refusing `www-data` at 169.254.169.254 |

Only `/var/www` survives a replacement. Everything else is rebuilt.

### A site

**Database naming.** For a site installed by the bootstrap, the database is the domain with dots
and hyphens replaced by underscores (`bugfloyd_com`), and the user is `wp_` followed by the first
twelve characters of `echo <domain> | md5sum`. The password is random and lives only in that
site's `wp-config.php`.

**The generated `wp-config.php`** sets the database connection, fresh salts, table prefix `wp_`,
and four things this stack depends on:

- **A protocol shim.** TLS ends at CloudFront, so PHP sees plain HTTP while WordPress's site URL is
  `https` — an infinite redirect on any page that enforces the canonical scheme, which is
  `wp-admin` and not the front page. The shim sets `HTTPS=on` when `CloudFront-Forwarded-Proto`
  (or a load balancer's `X-Forwarded-Proto`) says `https`.
- **`DISABLE_WP_CRON`** — a timer drives cron instead.
- **`DISALLOW_FILE_EDIT`** — no theme and plugin code editor in the admin screens.
- **`WP_AUTO_UPDATE_CORE = 'minor'`** — security and maintenance releases within the site's
  WordPress branch install themselves, driven by the cron runner. The files live once on the shared
  file system and cron runs on one instance, so each update happens once for every instance.
  Major releases, plugins and themes wait for someone to choose them.

Sites brought in from elsewhere keep whatever `wp-config.php` they arrived with, including their
own table prefix. Stacks created before minor updates were enabled carry
`AUTOMATIC_UPDATER_DISABLED` instead, which blocks every background update, security releases
included. Replace it by hand and restart OpenLiteSpeed:

```sh
sudo sed -i "s/define( 'AUTOMATIC_UPDATER_DISABLED', true );/define( 'WP_AUTO_UPDATE_CORE', 'minor' );/" /var/www/*/html/wp-config.php
```

**Virtual host.** Each site answers to `<domain>`, `www.<domain>` and `origin.<domain>`; the first
site in the list also takes `*`, so a request matching nothing still reaches a site. Document root
`/var/www/<domain>/html`, `.htaccess` rewrite rules honoured, gzip and Brotli on.

### Scheduled jobs

**WP-Cron**, every minute, starting three minutes after boot. Takes `/var/www/.wp-cron.lock`
non-blocking, then requests `wp-cron.php` for each site over `127.0.0.1` with the site's `Host` and
`CloudFront-Forwarded-Proto: https`, so cron callbacks see the scheme visitors do. With more than
one instance, exactly one runs each tick. Those requests appear in every site's access log once a
minute, from `127.0.0.1`.

The request carries no query string, and that is load-bearing (see
[What looks harmless and is not](#what-looks-harmless-and-is-not)). It goes over HTTP rather than
through WP-CLI because a PHP worker already has WordPress compiled in OPcache. WP-CLI has no OPcache
here and measured 0.8–1.7 seconds and up to 107 MB per site per run, loading everything from the
network file system each minute.

**Media sync**, every `media_sync_interval` (default ten minutes), starting three minutes after
boot. Takes `/var/www/.wp-media-sync.lock` non-blocking and exits unless `/var/www` is mounted.
For each site with a non-empty uploads directory:

```sh
aws s3 sync /var/www/<domain>/html/wp-content/uploads s3://<bucket>/wp-content/uploads \
  --exclude '*' --include '20[0-9][0-9]/*' --delete --only-show-errors --no-progress
```

It copies a file that is new, differs in size, or is newer at the source; `--size-only` would miss
a same-size re-save. `--delete` removes files deleted in WordPress, and honours the filter, so it
never touches keys outside the year folders. The mount check matters: an unmounted file system
looks like an empty directory, and `--delete` would mirror that by emptying the bucket. In the
template the command is one line on purpose — a shell continuation followed by a blank line ends
the command early without an error, and the sync then runs with no filter and no `--delete`.

### What looks removable and is not

- **`CGIRLimit` in the server config.** Without it OpenLiteSpeed launches PHP through its suEXEC
  helper, and this build ships no `lscgid` binary: every PHP request returns 503.
- **`create_before_destroy` on the instance role and profile.** Renaming replaces them, and AWS
  refuses to delete a profile still attached to a running instance.
- **`ignore_changes` on `engine_lifecycle_support` and `snapshot_identifier`.** Both are
  creation-only; without it, the first would show a change forever and the second would read as
  "replace this database with an empty one".
- **Metric math on the FSx storage alarm.** `StorageCapacityUtilization` does not exist for
  OpenZFS; an alarm on it sits in OK forever. FSx publishes `StorageCapacity` and
  `UsedStorageCapacity` in bytes.
- **The conditional ownership check.** A recursive `chown` over NFS is a round trip per file; run
  on every boot it held a replacement's bootstrap for minutes.
- **The loopback exemption in the origin-secret rule.** Without it wp-cron and the bootstrap's
  health check, which call the instance directly, would be refused like any other request that
  lacks the header.
- **The order the bootstrap installs the caching guard in.** The file goes in place before the
  `auto_prepend_file` line that loads it: PHP fails every request if that setting names a file that
  does not exist.
- **The viewer response function.** Without it browsers receive `stale-while-revalidate` and can
  show their own day-old copy of a page — including an anonymous copy after logging in.
- **The static-file exemption in the viewer request function.** Without it every logged-in page
  view would also refetch the theme's CSS and JavaScript from the origin.
- **`wp-imds-guard.service`.** Nothing breaks without it. It is the only thing between an exploited
  plugin and the instance role, and a unit rather than a one-off rule because user data runs only on an
  instance's first boot.
- **`enforce_origin_secret`.** It looks like a debugging switch, and it is the only safe way to
  add or rotate the secret on a running stack — see [Changing configuration](#changing-configuration).
- **`depends_on` from the log bucket's ACL to its ownership controls.** Buckets default to
  `BucketOwnerEnforced`, which rejects ACLs, and CloudFront's standard logging needs the
  `log-delivery-write` ACL.

### What looks harmless and is not

- **A `doing_wp_cron` value on the cron runner's request.** `wp-cron.php` reads it as the key of a lock
  its caller already holds and returns without running anything unless it matches the `doing_cron`
  transient. The response is still a 200. An earlier runner passed a timestamp, and no scheduled event
  ran on any site for days. Without the parameter, `wp-cron.php` takes the lock itself.
- **`env LSAPI_AVOID_FORK=200M` in the PHP external application.** It comes with OpenLiteSpeed's
  stock configuration and reads like a memory optimisation. It is what jammed the PHP pool for five
  minutes after every burst (see [Instance](#instance)).

---

## Operating it

### Set the region

```sh
export AWS_DEFAULT_REGION=eu-west-1
```

Every regional command in this README assumes it. A CLI defaulting to another region does not
error — it returns empty results from the wrong region, which look exactly like a resource that
does not exist. CloudFront, ACM for CloudFront and Route 53 are global or live in `us-east-1`;
Cost Explorer is queried in `us-east-1`.

### Prerequisites

- An AWS account and the AWS CLI
- [Terraform](https://developer.hashicorp.com/terraform/downloads) 1.10 or later
- Domains delegated to Route 53
- An AMI built from [aws-ols-mariadb-ami](https://github.com/bugfloyd/aws-ols-mariadb-ami) with
  `-var profile=web`, **in the same region as the stack** — images are regional, and one built
  elsewhere simply cannot be launched here

### Deploying

Every configuration here uses an S3 backend with native locking, configured by a
`backend_config.hcl` that is not committed:

```hcl
region = "eu-west-1"
bucket = "your-terraform-state-bucket"
```

One bucket holds every state, keyed by configuration — `aws-wp/state-backend/`,
`aws-wp/hostedzones/` and `aws-wp/infra/terraform.tfstate` — and a named workspace stores its state
under `env:/<workspace>/`.

**The bucket itself is `state-backend/`.** It is the one configuration that has to exist before the
others, so on a new account it runs with local state and then moves its own state into the bucket
it just created:

```sh
cd state-backend
terraform init
terraform apply -var infra_state_bucket=<name>
terraform init -backend-config backend_config.hcl -migrate-state
```

It keeps versioning on, which is the only way back from a corrupted or wrongly pushed state, and
carries `prevent_destroy`. There is deliberately no rule expiring old versions: they are the
recovery path, and they can contain secrets, so they are purged deliberately rather than on a
schedule. On an account where the bucket already exists, adopt it with an `import` block instead of
applying.

**Hosted zones first**, deployed separately so domain records outlive the infrastructure — a
`destroy` in `infra/` never touches DNS. Set `websites` to the list of domains, apply, and delegate
each domain to the name servers it outputs:

```sh
cd hostedzones
terraform init -backend-config backend_config.hcl
terraform apply
terraform output hosted_zone_name_servers   # delegate the domain to these
terraform output hosted_zone_ids            # the IDs infra/ needs in `domains`
```

**A zone that already exists** — created by hand, or by a configuration being retired — is adopted
rather than recreated. Add it to `websites`, write an `import` block for it, and check the plan
says *import* and *update in place* and never *create*: a recreated zone gets new name servers and
the domain stops resolving until the registrar is updated.

```hcl
import {
  to = aws_route53_zone.this["example.com"]
  id = "Z0123456789ABCDEFGHIJ"
}
```

**Then the stack.** `infra/terraform.tfvars` needs at least:

```hcl
stack_name                     = "wp-prod"
ols_image_id                   = "ami-..."
domains                        = { "example.com" = "Z0123456789" }   # domain => hosted zone ID
admin_ips                      = ["203.0.113.10/32"]
admin_public_key               = "ssh-ed25519 ..."
config_bucket_name             = "wp-prod-config-123456789012"
cloudfront_logging_bucket_name = "wp-prod-cloudfront-logs-123456789012"
alert_email                    = "you@example.com"

# for anything serving real traffic
db_deletion_protection = true
db_skip_final_snapshot = false
```

```sh
cd ../infra
terraform init -backend-config backend_config.hcl
terraform apply
```

A first apply takes around 20 minutes; the database is the long part (about 12), the file system
about 5. Then **confirm the SNS subscription** from the email AWS sends — until then no alarm
reaches anyone.

The region is a variable (`region`, default `eu-west-1`) in `infra/`, and fixed to `eu-west-1` in
`hostedzones/`.

To tear it down: `terraform destroy` in `infra/`. With deletion protection on, set
`db_deletion_protection = false` and apply first. Buckets that still hold objects or object
versions (config, logs, media), and a backup vault holding recovery points, stop a destroy until
they are emptied. Destroying `hostedzones/` as well gives every domain new name servers, which
means delegating them again.

On a versioned bucket `aws s3 rm --recursive` only adds delete markers; the versions and the
markers both have to go. In batches of 1,000:

```sh
B=<bucket>
while :; do
  aws s3api list-object-versions --bucket "$B" --max-items 1000 \
    --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' --output json > batch.json
  [ "$(python3 -c "import json;print(len(json.load(open('batch.json'))['Objects'] or []))")" = 0 ] && break
  aws s3api delete-objects --bucket "$B" --delete file://batch.json >/dev/null
done
```

Destroying the file system also leaves a final backup behind (see
[Backups and recovery](#backups-and-recovery)).

### Adding a site

Create its hosted zone (add it to `websites` in `hostedzones/`), then add it to `domains` and
apply. The instance is replaced, its bootstrap installs WordPress for the new domain, and the
domain gets a certificate, a distribution, DNS records and a media bucket. Visit
`https://<domain>/wp-admin/install.php` to finish the install. Until then its login page redirects
to the installer, which the canary counts as a failure.

### Reaching the instance

```sh
IID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=WebserverInstance \
        Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text)

# a shell, no key or inbound rule
aws ssm start-session --target "$IID"

# one command, no shell
CID=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
        --parameters 'commands=["systemctl is-active lsws"]' --query Command.CommandId --output text)
aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" --query StandardOutputContent --output text
```

While two stacks coexist the tag matches both instances; use the instance ID from Terraform state
instead. SSH (`ssh ubuntu@<elastic-ip>`) works from `admin_ips` as a fallback.

**WebAdmin**, which listens on loopback only:

```sh
aws ssm start-session --target "$IID" --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["7080"],"localPortNumber":["7080"]}'
# https://localhost:7080 - user admin, password:
aws ssm get-parameter --name /<stack_name>/ols/admin-password --with-decryption --query Parameter.Value --output text
```

**The database**, from the instance. As a site's own user (credentials in its `wp-config.php`), or
as the master user, whose password RDS keeps in Secrets Manager and rotates:

```sh
wp-site <domain> db cli

aws secretsmanager get-secret-value --secret-id $(terraform output -raw db_master_secret_arn) \
  --query SecretString --output text                  # from your machine, in infra/
mysql -h <db_endpoint> -u wpadmin -p                   # on the instance
```

### Updating WordPress, plugins and themes

Minor WordPress releases install themselves (see [A site](#a-site)); a notice email would say so,
but outbound email is a [known gap](#known-gaps). Everything else goes through the admin screens,
as usual — within limits. Each update rewrites files on network
storage and must finish inside CloudFront's 120-second origin timeout. A 5,872-file plugin takes
about 39 seconds. For anything larger, or when the admin screens are the problem, use WP-CLI on
the instance:

```sh
wp-site <domain> plugin update --all
wp-site <domain> core update
```

### Changing configuration

Any change to the bootstrap, the rendered OpenLiteSpeed config, `php_settings`, `php_children`,
`php_extra_children`, `domains`, `media_sync_interval` or the AMI replaces the instance. The old one is terminated first,
so for a few minutes cached pages and S3 media keep serving while everything else returns 5xx; the
instance-status alarm fires and clears once (see [Alerts](#alerts)). Changing `instance_type`
stops and starts the same instance instead. To replace it deliberately:

```sh
terraform apply -replace=aws_instance.webserver
```

**After editing any file on the instance by hand — `wp-config.php` in particular — restart
OpenLiteSpeed**, or OPcache may keep running the old version for up to fifteen minutes:

```sh
sudo /usr/local/lsws/bin/lswsctrl stop; sudo /usr/local/lsws/bin/lswsctrl start
```

**Rotating the origin secret** takes three applies. CloudFront needs several minutes to deploy a new
value to every edge location, and an instance that already enforces a value the edges do not yet
send answers 403 to all uncached traffic:

```sh
terraform apply -var enforce_origin_secret=false          # instance replaced, check off
terraform apply -var enforce_origin_secret=false -replace=random_password.origin_secret
aws cloudfront wait distribution-deployed --id <id>       # for each distribution
terraform apply                                           # instance replaced, check on
```

The same last two steps added the header to this stack when it was first introduced. A stack built
from scratch needs none of it: its distributions carry the header from the moment they exist.

**Tuning the cache.** Every rule is a variable:

| Variable | Default | Changes |
| -------- | ------- | ------- |
| `page_cache_ttl` | 420 | seconds a public page stays fresh at the edge |
| `page_stale_while_revalidate` | 39600 | how long after that the old copy answers while CloudFront refreshes; with `page_cache_ttl`, at most 12 hours |
| `page_stale_if_error` | 86400 | how long the old copy answers while the origin is failing |
| `cache_bypass_cookie_prefixes` | WordPress, WooCommerce, EDD | cookies that make a request personal — add a plugin's own session cookie here |
| `cache_ignored_query_strings` | ten tracking parameters | query strings left out of the cache key (at most 10) |
| `edge_blocked_files` | `wp-cron.php`, `xmlrpc.php` | file names answered with 403 at the edge |

The three page timings live in the origin guard, so changing them replaces the instance; the other
three only update the CloudFront function or policy.

**Rotating the WebAdmin password:** the bootstrap reads it at boot, so replace both together:
`terraform apply -replace=random_password.ols_admin -replace=aws_instance.webserver`.

### Replacing a whole stack

A fresh stack beside the current one, cut over at the edge — how production moved from EFS to
FSx, with about five minutes of downtime. The order matters.

1. **Workspace and variables.** `terraform workspace new <stack>`, and a `<stack>.tfvars` overriding
   `stack_name`, `key_pair_name = null`, `edge_policy_suffix`, both explicit bucket names, the
   production database settings, and `db_snapshot_identifier`. `terraform.tfvars` still loads in
   every workspace, so anything that must be unique has to be overridden. Pass
   `-var-file=<stack>.tfvars` to every command.
2. **Snapshot the current database** (`aws rds create-db-snapshot`).
3. **Storage and database only**:
   `terraform apply -var enable_edge=false -target=aws_fsx_openzfs_file_system.websites -target=aws_db_instance.websites`.
   About 15 minutes. The instance must not exist yet: on an empty file system its bootstrap would
   install WordPress and reset the restored database users' passwords.
4. **Copy the files** with AWS DataSync — two VPCs cannot mount each other's storage, and
   overlapping ranges cannot peer. Each location borrows its own stack's web security group, which
   its file system already admits. For FSx the subdirectory is `/fsx/`. Task options:
   `OverwriteMode=ALWAYS, PreserveDeletedFiles=REMOVE, Uid=INT_VALUE, Gid=INT_VALUE,
   PosixPermissions=PRESERVE, TransferMode=CHANGED`, with a CloudWatch log group so a failed
   verification names its files — the group needs a resource policy letting
   `datasync.amazonaws.com` write to it, or the task's `LogLevel` cannot be set. The first run
   against a live site reports mismatches (files change under it); run it again. For scale:
   34,479 files and 838 MB took 86 seconds to transfer and 69 to verify.
5. **Everything else**: `terraform apply -var enable_edge=false`. The bootstrap skips every site,
   and its health poll fails, because each `wp-config.php` still names the old database.
6. **Final DataSync run, then delete the task.** Only then, on the new instance:

   ```sh
   sed -i -E "s|('DB_HOST',[[:space:]]*')[^']*(')|\1<new-endpoint>\2|" /var/www/*/html/wp-config.php
   /usr/local/lsws/bin/lswsctrl stop; rm -f /tmp/lshttpd/*.sock*; /usr/local/lsws/bin/lswsctrl start
   systemctl start wp-media-sync.service
   ```

   A DataSync run after the rewrite puts the old host back.
7. **Verify before touching DNS.** Per site, on the instance: `/` and `/wp-login.php` answer 200
   through `127.0.0.1` with its `Host` and `CloudFront-Forwarded-Proto: https`;
   `wp-site <domain> db check` passes; post, comment and option counts and the latest
   modification dates match the old database; the media bucket holds as many objects as the
   site's `uploads/20??/` folders hold files.
8. **Cut over.** Save each old distribution's config as JSON — restoring those is the rollback.
   Set each one's aliases to empty and its certificate to the CloudFront default, then at once
   `terraform apply -var enable_edge=true`. CloudFront accepts the aliases on the new
   distributions without waiting for the old ones to finish deploying.
9. **Prove traffic reaches the new stack.** Each domain's alias targets a new distribution; an
   existing image returns `x-amz-server-side-encryption` (only the new stack has an S3 origin);
   the TLS serial is the new certificate's; on every site, an unmirrored year-folder file returns
   that site's own content; a file in a plugin directory under `uploads` comes from the instance,
   not S3; the canary passes, the alarms settle to OK (`instance-status-failed` sits in ALARM for
   about five minutes after any launch), and the subscription is confirmed.
10. **Retire the old stack after several days**, once the new one has its own backups:
    - Snapshot its database by hand: a destroy deletes the automated backups too.
    - Remove from its state the DNS records the new stack now owns — the apex and `www` aliases
      **and the `cert_validation` records**. ACM reuses one validation record per domain per
      account, so destroying them succeeds and silently breaks the new certificates' renewal.
    - Empty its buckets, versions and delete markers included (`aws s3 rm` on a versioned bucket
      only adds markers), and delete its vault's recovery points.
    - `terraform plan -destroy`, and read it: no new-stack resource, no `route53_record`. Then
      destroy, detached (`nohup`) — deleting distributions takes 20-30 minutes.
    - Delete the RDS and canary log groups and the manual snapshots it leaves behind.
    - Move the new stack's state into the default workspace (`state pull`, then `state push -force`
      into the now-empty default state), fold `<stack>.tfvars` into `terraform.tfvars`, confirm
      `terraform plan` reports no changes, and delete the named workspace.

With `enable_edge=false`, a new stack's canary checks the live domains, which the old stack is
still serving; it proves nothing about the new one until cutover.

---

## Logs

| Log | Where | Retention | Survives replacement |
| --- | ----- | --------- | -------------------- |
| Bootstrap | `/var/log/wp-bootstrap.log`, `/var/log/cloud-init-output.log` | the instance's life | no |
| Per-site access | `/var/www/<domain>/logs/access.log` | 10 MB files, 7 days, compressed | yes |
| Per-site server errors | `/var/www/<domain>/logs/error.log` (level ERROR) | 10 MB files, 7 days | yes |
| OpenLiteSpeed server | `/usr/local/lsws/logs/error.log` (ERROR), `stderr.log`, `lsrestart.log` | 10 MB files, 7 days | no |
| WebAdmin | `/usr/local/lsws/admin/logs/error.log`, `access.log` | 10 MB files; access 90 days | no |
| Scheduled jobs | `journalctl -u wp-cron.service`, `journalctl -u wp-media-sync.service` | systemd journal | no |
| SSM agent | `/var/log/amazon/ssm/amazon-ssm-agent.log` | agent default | no |
| CloudFront access | `s3://<cloudfront_logging_bucket_name>/<domain>/web/`, gzipped, delivered within about an hour; no cookies | 5 years | — |
| Canary run artifacts | `s3://<cloudfront_logging_bucket_name>/canary/eu-west-1/<canary>/YYYY/MM/DD/HH/` (request and step reports) | 5 years, the bucket's lifecycle | — |
| Canary run history | CloudWatch Synthetics console, `aws synthetics get-canary-runs` | 2 days passed, 14 days failed | — |
| Canary execution | CloudWatch Logs `/aws/lambda/cwsyn-<stack_name>-origin-<id>` | never expires | — |
| Database errors | CloudWatch Logs `/aws/rds/instance/<stack_name>-mysql/error` | never expires | — |

**CloudFront's logs leave cookies out** (`include_cookies = false`). With them in, every WordPress
session cookie of anyone who logged in would sit in the log bucket for five years.

The per-site access log format is `%v %h %l %u %t "%r" %>s %b` — site, client address, time,
request line, status, bytes; no referrer or user agent. **The client address is a CloudFront edge,
not the visitor** (see [Known gaps](#known-gaps)). The server-level `access.log` stays empty
because every site logs separately. For referrers, user agents, viewer addresses, edge cache
results and timings, use the CloudFront logs.

**PHP errors are not logged by default.** PHP has no `error_log` set, and nothing PHP reports
reaches any log above. To capture them for one site, set `WP_DEBUG` to `true` in its
`wp-config.php` and add the two lines below next to it, restart OpenLiteSpeed so OPcache picks up
the change, reproduce, then revert and restart again:

```php
define( 'WP_DEBUG_LOG', '/var/www/<domain>/logs/php-debug.log' );
define( 'WP_DEBUG_DISPLAY', false );
```

Give `WP_DEBUG_LOG` a path, not `true`: `true` writes `wp-content/debug.log`, inside the document
root and downloadable by anyone who guesses the URL. The site's `logs` directory is on the file
system, outside the document root, and writable by the web user.

**The slow query log is exported but off.** `slowquery` is enabled for CloudWatch export, but the
parameter group does not set `slow_query_log = 1`, so nothing is written. Set it (and
`long_query_time`) in `database.tf` to use it.

Reading them:

```sh
# on the instance
sudo tail -f /var/www/<domain>/logs/access.log /var/www/<domain>/logs/error.log
sudo tail -n 50 /usr/local/lsws/logs/error.log
sudo journalctl -u wp-media-sync.service -n 20

# from anywhere
aws logs tail /aws/rds/instance/<stack_name>-mysql/error --since 1h
aws s3 ls s3://<cloudfront_logging_bucket_name>/<domain>/web/ | tail
aws s3 cp s3://<cloudfront_logging_bucket_name>/<domain>/web/<file>.gz - | gunzip | tail
aws synthetics get-canary-runs --name <stack_name>-origin --max-results 5 \
  --query 'CanaryRuns[].[Status.State,Status.StateReason,Timeline.Started]' --output table
aws logs tail $(aws logs describe-log-groups --log-group-name-prefix /aws/lambda/cwsyn-<stack_name>-origin \
  --query 'logGroups[0].logGroupName' --output text) --since 2h
```

---

## Alerts

Every alarm publishes both ALARM and OK to the SNS topic `<stack_name>-alerts`, which emails
`alert_email`. **AWS emails a confirmation link when the subscription is created, and nothing is
delivered until it is clicked.** Terraform cannot click it and the apply does not fail. Check it
after any change to the topic. A subscription can also disappear later without any error, and an
unsubscribe through an email link leaves no CloudTrail record:

```sh
aws sns list-subscriptions-by-topic --topic-arn $(terraform output -raw alerts_topic_arn) \
  --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output text
# a full ARN means confirmed; "PendingConfirmation" or "Deleted" means no email is sent
```

**To stop a subscription vanishing**, confirm it from the CLI instead of clicking the link. Copy
the `Token` parameter out of the confirmation link and pass it with
`--authenticate-on-unsubscribe`, after which unsubscribing requires AWS credentials and the
unsubscribe link in each email stops working:

```sh
aws sns confirm-subscription --topic-arn $(terraform output -raw alerts_topic_arn) \
  --token <Token from the confirmation link> --authenticate-on-unsubscribe true
```

| Alarm | Fires when | Evaluated | Missing data | Means |
| ----- | ---------- | --------- | ------------ | ----- |
| `<stack_name>-origin-canary-failed` | the canary's `SuccessPercent` < 100 | one run (period derived from the schedule) | breaching | a site is not serving WordPress, whatever CloudFront still returns from cache — or the canary stopped running |
| `<stack_name>-instance-status-failed` | EC2 `StatusCheckFailed` > 0 | 3 × 1 minute | breaching | the instance is failing its hardware or OS checks, or has stopped reporting |
| `<stack_name>-rds-storage-low` | `FreeStorageSpace` < 2 GiB | 2 × 5 minutes | not breaching | the database is nearly full: autoscaling has reached `db_max_allocated_storage`, or has not caught up (it waits six hours between increases) |
| `<stack_name>-fsx-storage-high` | used / provisioned storage > 80 % | 3 × 5 minutes | not breaching | the file system is filling up; it does not grow by itself |
| `<stack_name>-fsx-throughput-high` | `NetworkThroughputUtilization` > 80 % | 3 × 5 minutes | not breaching | file operations are queuing against provisioned throughput |

**The canary** is the only check that behaves like a reader. Hourly by default, it requests
`https://<domain>/wp-login.php` for every site and fails the run unless the response is 200 and
the body contains a login form. That page cannot be served from CloudFront's cache and only renders
if PHP ran and WordPress reached the database — so it catches the failure the infrastructure
alarms cannot: OpenLiteSpeed broken on a healthy instance while CloudFront keeps serving cached
front pages.

| `canary_schedule_expression` | Runs/month | Cost | Worst-case time to alert |
| ---------------------------- | ---------- | ---- | ------------------------ |
| `rate(5 minutes)` | 8,640 | ~$12.10 | ~5 min |
| `rate(15 minutes)` | 2,880 | ~$4.03 | ~15 min |
| `rate(1 hour)` (default) | 730 | ~$1.02 | ~1 hour |

An outage shorter than the interval can fall between two runs, and an hourly alarm takes up to an
hour to clear after recovery. The alarm period is derived from the expression, because a fixed
five-minute period against an hourly canary leaves eleven windows in twelve empty — which the
breaching missing-data rule turns into a permanent alarm. Set `enable_canary = false` to drop it.

**Expected false alarms:**

- **Every instance replacement.** A new instance starts publishing status-check metrics about five
  minutes after launch, and missing data counts as failing. Expect an ALARM and an OK email.
- **A site added but not yet installed.** Its login page redirects to the installer, which fails
  the canary until the install is finished.

Any other canary failure is real. The ones before the pool fix were `Connection timed out`: the first
request hung inside a PHP pool jam while CloudFront kept serving cached pages. If they come back, count
`Reached max children` lines in `/usr/local/lsws/logs/stderr.log` for that minute.

---

## Debugging

**Start with where the failure is.** From outside:

```sh
for p in / /wp-login.php /wp-admin/; do curl -s -o /dev/null -w "$p %{http_code} %header{x-cache}\n" https://<domain>$p; done
```

A 200 homepage with `Hit from cloudfront` proves only that CloudFront has a copy; `/wp-login.php` is
never cached. Then from the instance, bypassing CloudFront:

```sh
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: <domain>' -H 'CloudFront-Forwarded-Proto: https' http://127.0.0.1/wp-login.php
```

**Dynamic pages fail, cached pages work** (the canary alarm):

```sh
systemctl is-active lsws; pgrep -c lsphp
sudo tail -n 50 /usr/local/lsws/logs/error.log /var/www/<domain>/logs/error.log
wp-site <domain> db check
free -m; swapon --show
```

A 503 on every PHP request with `cgidSuEXEC failed` means `CGIRLimit` is missing. `Failed to lock
pid file` means stale sockets in `/tmp/lshttpd`: stop, clear them, start.

**"Error establishing a database connection".** Check `DB_HOST` in the site's `wp-config.php`, that
the database is `available`, and — if the file was edited recently — restart OpenLiteSpeed, since
OPcache may still hold the old version.

**An instance never comes up after a replacement.**

```sh
aws ec2 get-console-output --instance-id "$IID" --latest --output text | tail -40
# once Session Manager works:
cloud-init status --long; sudo cat /var/log/wp-bootstrap.log
```

`FATAL: could not mount` points at the file system: its security group must admit the web security
group on 2049, and the mount must not use `noresvport`. Repeated `curl: (22) ... error: 500` lines
before `wp-bootstrap finished` mean OpenLiteSpeed is up and WordPress is failing — often a
`wp-config.php` naming a database this VPC cannot reach. `curl: (7) Failed to connect` means
OpenLiteSpeed itself did not start; see its `error.log`.

**504 from CloudFront on an admin action.** It took longer than the 120-second origin timeout. The
action may still have finished on the instance; re-check, and use WP-CLI for anything that large.

**An image on one site shows another site's page.** The fallback reached the instance with a `Host`
no virtual host matches. Check that `origin.<domain>` resolves to the Elastic IP and appears in the
listener map in `/usr/local/lsws/conf/httpd_config.conf`.

**A new image is broken for a few minutes.** It is waiting for the next sync and the instance
fallback failed; see the previous entry. To mirror at once: `sudo systemctl start wp-media-sync.service`.

**Reading `x-cache`.** `Hit from cloudfront` is a cached copy; `Miss` went to the origin — and a
personal request is always a `Miss`; `FunctionGeneratedResponse` is the viewer request function
answering by itself (the 403 for a blocked file). `Age` is how old the cached copy is: a `Hit` with
an `Age` above `page_cache_ttl` is a stale copy, served while CloudFront refreshes in the background
or while the origin is failing. To see what the origin itself says, ask it
over loopback on the instance:

```sh
curl -s -o /dev/null -D - -H 'Host: <domain>' -H 'CloudFront-Forwarded-Proto: https' http://127.0.0.1/<path> | grep -i cache-control
```

**Logged in, but seeing the public page.** A logged-in request is always a `Miss`. If it is a `Hit`,
the request carries no cookie from `cache_bypass_cookie_prefixes` — a login plugin with a session
cookie of its own, say. Add its prefix.

**A page is cached that should not be** — a plugin shows per-visitor content without a cookie and
without `no-cache`. Give it a personal cookie prefix, or have the plugin send `no-cache`; if the
page sets a cookie, the guard already stops it being cached.

**A change does not show up for visitors.** Public pages stay fresh for 7 minutes and static files
for seven days (see [What serves a request](#what-serves-a-request)); a logged-in editor bypasses
the cache and sees the change at once. Invalidate what changed, or the whole site:

```sh
aws cloudfront list-distributions --query "DistributionList.Items[].[Id,Aliases.Items[0]]" --output text
aws cloudfront create-invalidation --distribution-id <id> --paths "/*"
```

The first 1,000 invalidation paths each month are free, and `/*` counts as one. A year-folder media
file edited in place (WordPress never does this) needs its path invalidated too.

**Scheduled posts miss their time, or plugins' background jobs stall.** List what is overdue:

```sh
wp-site <domain> cron event list --due-now --fields=hook,next_run_relative
journalctl -u wp-cron.service -n 5
```

A minute after a tick nothing should be listed. Events that stay overdue mean `wp-cron.php` is
returning without running them. Check that the runner's request in
`/usr/local/bin/wp-cron-runner.sh` has no query string.

**Media is not reaching S3.** `journalctl -u wp-media-sync.service`; run
`sudo /usr/local/bin/wp-media-sync.sh` by hand; check `/etc/wp-media-sync.conf`; confirm the mount.
The script exits silently if another instance holds its lock.

**Every uncached request returns 403 through CloudFront, but the instance works locally.** The
origin secret does not match — typically a rotation applied in one step, or distributions still
deploying a new value. OpenLiteSpeed's 403 is an HTML page titled `403 Forbidden`, where S3's is an
XML `AccessDenied`. Requests over `127.0.0.1` are exempt, so they keep working and prove the site
itself is fine; the refused requests show in the site's access log as 403s from CloudFront edge
addresses. Turning the check off restores service while the cause is found:
`terraform apply -var enforce_origin_secret=false`.

**No alarm emails.** Check the subscription (see [Alerts](#alerts)).

**Terraform reports a held lock after an interrupted apply.** Make sure no Terraform process is
alive — `pgrep -x terraform`, not `pgrep -f`, which matches any command line containing the word —
then read the lock ID and release it:

```sh
aws s3 cp s3://<state-bucket>/aws-wp/infra/terraform.tfstate.tflock -              # default workspace
aws s3 cp s3://<state-bucket>/env:/<workspace>/aws-wp/infra/terraform.tfstate.tflock - # any other
terraform force-unlock <ID>
```

---

## Backups and recovery

| What | Backed up by | Schedule | Retention | Where |
| ---- | ------------ | -------- | --------- | ----- |
| Database | RDS automated backups, with point-in-time recovery | daily, 02:00–03:00 UTC, plus transaction logs | 30 days | RDS snapshots `rds:<stack_name>-mysql-<date>` |
| File system (all sites' files and media) | AWS Backup | daily, 03:00 UTC (must start within an hour, finish within three) | 30 days | vault `<stack_name>-backup-vault`, named `<stack_name>-fsx-daily` |
| Database, on destroy | final snapshot, when `db_skip_final_snapshot = false` | once | until deleted | `<stack_name>-mysql-final` |
| File system, on destroy | FSx final backup (`skip_final_backup` defaults to `false`) | once | until deleted | FSx backups, **outside the vault**, named `<stack_name>-fsx-final` |
| Manual database snapshots | you, with `aws rds create-db-snapshot` | before risky changes | until deleted | RDS snapshots |
| OpenLiteSpeed configuration | S3 versioning | every apply | indefinite | the config bucket |
| Terraform state | S3 versioning on the state bucket | every apply | indefinite | the state bucket |

**Not backups:** the media buckets (a serving copy of the file system, rebuilt by the sync), the
instance's root volume (everything on it is rebuilt at boot; only server logs are lost), and changes
made through WebAdmin (lost by design).

**Destroying the database deletes its automated backups** (the provider's default,
`delete_automated_backups = true`); only a final or manual snapshot survives it.

The file system's own automatic backups are off (`automatic_backup_retention_days = 0`) so AWS
Backup is the single schedule; running both would pay twice for the same recovery points.

**Destroying the file system leaves a final backup behind.** FSx takes one on deletion unless told
not to. It is a native FSx backup, not an AWS Backup recovery point, so it sits outside the vault
and never expires. `final_backup_tags` names it `<stack_name>-fsx-final`; without them it would
have no name at all, and it only takes effect if applied before the destroy. It is a useful safety
net after replacing a stack; delete it deliberately once it is no longer needed:

```sh
aws fsx describe-backups --query 'Backups[?Type==`USER_INITIATED`].[BackupId,CreationTime,FileSystem.FileSystemId]' --output table
aws fsx delete-backup --backup-id <id>
```

```sh
aws rds describe-db-snapshots --db-instance-identifier <stack_name>-mysql --query 'DBSnapshots[].[DBSnapshotIdentifier,SnapshotCreateTime]' --output table
aws rds describe-db-instances --db-instance-identifier <stack_name>-mysql --query 'DBInstances[0].LatestRestorableTime'
aws backup list-recovery-points-by-backup-vault --backup-vault-name <stack_name>-backup-vault \
  --query 'RecoveryPoints[].[CreationDate,Status,BackupSizeInBytes]' --output table
```

**Recovering a database.** Every RDS restore creates a new instance, never an in-place rewind.

- *A whole stack's data* — restore or snapshot into a replacement stack with
  `db_snapshot_identifier`, as in [Replacing a whole stack](#replacing-a-whole-stack). This is the
  path production has actually used.
- *One site, or a point in time* — restore to a temporary instance beside the live one, dump that
  site's database from the web instance with `mysqldump`, using the site's own user and password
  from its `wp-config.php` (they are in the restored copy too), load it into the live database,
  then delete the temporary instance.

```sh
aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier <stack_name>-mysql \
  --target-db-instance-identifier <stack_name>-mysql-recovery --restore-time <ISO-8601> \
  --db-subnet-group-name <stack_name>-db-subnet-group --db-parameter-group-name <stack_name>-mysql84 \
  --vpc-security-group-ids <the database's security group> \
  --db-instance-class db.t4g.micro --no-publicly-accessible
```

**Recovering files.** Restoring an FSx recovery point also creates a new file system rather than
rewinding the live one. Restore it into the stack's data subnet and file system security group,
mount it on the instance beside `/var/www`, and copy back what is needed with
`rsync -aH --numeric-ids`, which preserves the uid 33 ownership WordPress needs. This path has not
yet been exercised on this stack; try it on a spare restore before relying on it.

---

## Cost

Measured, not estimated: the rates below are what AWS billed this account in eu-west-1, and the
monthly figures come from a full metered day (2026-09-17) with this stack's usage isolated from
the account's other resources. About **$58 a month before tax**, for three low-traffic sites.

| Item | Billed rate | Monthly |
| ---- | ----------- | ------- |
| FSx for OpenZFS throughput, 64 MB/s | $0.286 per MB/s-month | $18.30 |
| FSx for OpenZFS SSD storage, 64 GiB | $0.099 per GB-month | $6.34 |
| RDS `db.t4g.micro` | $0.017 per hour | $12.41 |
| RDS gp3 storage, 20 GB | $0.127 per GB-month | $2.54 |
| EC2 `t3.micro` | $0.0114 per hour | $8.32 |
| Public IPv4 address (the Elastic IP; billed whether or not attached) | $0.005 per hour | $3.65 |
| EBS gp3 root volume, 20 GB | $0.088 per GB-month | $1.76 |
| Route 53, three hosted zones | $0.50 per zone | $1.50 |
| Canary runs, hourly | $0.0014 per run | $1.02 |
| Canary metrics, 14 of them | $0.30 per metric-month | $4.20, less 10 free: **$1.20** |
| CloudWatch alarms, six alarm metrics | $0.10 per alarm-month | $0.60, less 10 free: **$0** |
| Secrets Manager, the RDS master secret | $0.40 per secret | $0.40 |
| AMI snapshot, 8 GB | $0.05 per GB-month | ~$0.20 |
| S3 storage and requests, DNS queries, FSx backup storage | usage | ~$0.30 |
| CloudFront | 1 TB and 10M requests free | $0 |
| CloudFront Functions, two per page request | 2M invocations free, then $0.10 per million | $0 |
| **Total, before tax** | | **~$58** |

**Free tiers do a lot of work here**, and they are account-wide, so a busier account pays list:
$62 rather than $58. The ten free custom metrics and ten free alarms are the difference.

**The canary costs more in metrics than in runs.** It publishes eight canary-level metrics plus a
`Duration` and a `SuccessPercent` per site, so each site added is $0.60 a month more in metrics —
more than the site's share of the runs. Lowering `canary_schedule_expression` does not touch that half.

**Charges that do not appear:**

- **Data transfer.** CloudFront's fetches from an AWS origin are free, S3 in the same region is
  free, and the instance, file system and database are pinned to one Availability Zone. A database
  in the other zone pays $0.01 per GB each way — about $0.55 a month on the stack this replaced,
  which is why `availability_zone` is set.
- **Database backups.** RDS backup storage up to the provisioned 20 GB is free.
- **File system backups** cost $0.05 per GB-month, about $0.06 at this data size.

**Tax comes on top** — 21 % VAT on this account, making it about $70.

The file system is 42 % of the bill and buys speed, not savings. Adding a site to an existing
stack costs a hosted zone, two canary metrics and some requests — about $1.20 a month. Two costs
worth watching: **RDS Extended Support** ($172 a month on this instance class if the engine
version lapses — see [Database](#database)) and **the canary schedule** (see [Alerts](#alerts)).

---

## Known gaps

| Gap | Detail |
| --- | ------ |
| **Visitor addresses are lost** | OpenLiteSpeed's `useIpInProxyHeader 2` uses `X-Forwarded-For` only from trusted IPs, and none are configured. Logs and PHP see the CloudFront edge's address, which affects comment IPs, spam filtering and rate limiting. Trusting the header from every peer is not a safe fix alone: viewers can send their own. A robust fix reads the `CloudFront-Viewer-Address` header, which CloudFront sets and viewers cannot. |
| **PHP errors are not logged by default** | See [Logs](#logs) for capturing them per site. |
| **The slow query log is off** | Exported to CloudWatch, never written. |
| **Nothing replaces a broken instance** | EC2's default automatic recovery moves the instance to healthy hardware when its host fails, but a broken OS or web server is only reported, by the canary. No Auto Scaling group acts on it until the Scalable stage. |
| **Content changes wait on the edge cache** | An edit or an approved comment reaches anonymous visitors within about 7 minutes, and on a quiet page one visit later. Nothing purges CloudFront on publish; a WordPress plugin that invalidates the changed pages from the instance's role (C3 CloudFront Cache Controller, for one) would make it immediate, at the cost of a plugin inside WordPress and CloudFront permissions on the instance. |
| **Single Availability Zone** | The instance, the file system and the database each live in one zone. The Resilient stage fixes it. |
| **A false alarm per instance replacement** | See [Alerts](#alerts). |
| **Server logs do not survive replacement** | Per-site logs live on the file system; the bootstrap and server logs do not. |
| **Large admin-panel updates are bounded** | By the 120-second origin timeout. WP-CLI is not. |
| **Service-created logs never expire** | The canary's and RDS's CloudWatch log groups have no retention and outlive their canary or database; canary artifacts in S3 follow the log bucket's five-year lifecycle. |
| **Provider versions float** | `.terraform.lock.hcl` is not committed, so providers resolve within their constraints at `init`. |

---

## Later stages

Constraints the current code imposes on what comes next:

| Stage | Changes | Notes |
| ----- | ------- | ----- |
| Scalable | Private subnets, NAT gateway, ALB, launch template, Auto Scaling group | The instance moves off its Elastic IP and behind the load balancer, which restores a real health check and can replace a failed instance — see below. The protocol shim already honours `X-Forwarded-Proto`. The first site's `*` listener mapping lets a load balancer's health check, which addresses the target by IP, reach a site. Cron and media sync already elect a single runner across instances. |
| Resilient | Instances across AZs, NAT per AZ, `multi_az = true`, Multi-AZ FSx | RDS Multi-AZ is an in-place modify, but the `availability_zone` pin has to go in the same change: RDS rejects the two together. FSx Single-AZ to Multi-AZ ($75.55/month) is a new file system, and the data moves with DataSync. |
| Cached | ElastiCache per AZ in the data subnets, LiteSpeed Cache plugin | The data subnets are `/24`s, with ample room beside RDS. The server cache module is present with `enableCache = 0` (`enable_ols_cache`), so enabling it is a value change. A page cache on each instance goes stale across instances: let CloudFront be the shared page cache and purge on publish, or accept a short TTL. Do not put the cache root on the shared file system. LiteSpeed Cache rather than W3 Total Cache, because it drives the server's own cache module. |
| Reference | Aurora with a read replica, read/write splitting (HyperDB), dashboard | The one stage with a data migration: Aurora is built from an RDS snapshot, or as an Aurora read replica that is promoted, not modified in place. `DB_HOST` is written into each site's `wp-config.php` only at install, so an endpoint change is a rewrite of each config plus an OpenLiteSpeed restart — not a template change. |

### Carrying into the Scalable stage

An earlier load balancer and Auto Scaling draft, since deleted, established these:

- **The origin-secret check moves from OpenLiteSpeed to the load balancer.** A listener rule
  forwards only requests carrying `X-Origin-Verify`, and the listener's default action is a fixed
  403. The virtual host rewrite rule has to go in the same change: load balancer health checks
  do not carry the header and do not come from loopback, so the rule would fail every one of them,
  mark every target unhealthy, and have the group replace instances forever. CloudFront's custom
  header moves to the load balancer origin, and the load balancer's security group keeps the
  CloudFront prefix list. `enforce_origin_secret` goes with the rule.
- **Or drop the secret entirely with CloudFront VPC origins.** An internal load balancer in the
  private subnets, reached by CloudFront privately, has no public address to protect. It needs the
  NAT gateway this stage adds anyway, for the instances' outbound traffic. It removes the load
  balancer's public addresses but not the NAT gateway's.
- **Instance refresh at a desired capacity of one** needs a minimum healthy percentage of 100 and
  a maximum of 200, with `max_size` at least one above the desired capacity. Anything lower lets
  the group terminate the only instance before its replacement is in service, so every
  configuration change becomes an outage.
- **Health checks that tolerate provisioning:** check `/` accepting 200-399, not
  `/wp-login.php` — the bootstrap's placeholder page passes at once and a fresh WordPress redirects
  to its installer — with a grace period of about 600 seconds. Too short and the group kills
  instances mid-bootstrap, which never resolves on its own.
- **The web tier stays in one Availability Zone** until the Resilient stage. Instances in two
  zones while the database and NAT gateway sit in one is theatre.
- **The edge caching layers carry over unchanged.** The functions and policies live in CloudFront,
  and the origin guard is installed by the bootstrap on every instance.
- **Verify single-runner locking with two instances.** Cron, media sync and first-time WordPress
  installs each take a non-blocking `flock` on the shared file system, so exactly one instance runs
  them. That design is in place but has only ever run on one instance: confirm with two that one
  runs each tick and the other exits, and that a lock held by a terminated instance is released.
- **The load balancer's certificate** reuses the CloudFront certificate's DNS validation records,
  which ACM issues identically per domain per account.

Graviton (arm64) is not yet supported by the AMI build, which is x86-only — its SSM agent package,
for one, is the `amd64` build. It saves about 20 % per instance and becomes worth an AMI change
once there are several instances.

---

## Repository layout

| Path | Contents |
| ---- | -------- |
| `state-backend/` | The S3 bucket holding every other configuration's state |
| `hostedzones/` | Route 53 hosted zones, separate state |
| `infra/backend.tf` | S3 backend, provider requirements |
| `infra/main.tf` | Providers, the per-domain edge module |
| `infra/variables.tf` | Every input, with defaults and validation |
| `infra/network_networks.tf`, `network_gateways.tf`, `network_routes.tf` | VPC, subnets, gateway, routes |
| `infra/webserver.tf`, `webserver_network.tf` | Instance, Elastic IP, key pair, security group |
| `infra/instance_iam.tf` | Instance role, Session Manager, bootstrap permissions |
| `infra/fsx.tf` | File system, its security group and alarms |
| `infra/database.tf` | Database, subnet and parameter groups, security group |
| `infra/media.tf` | Media buckets, origin access control, bucket policies, sync permissions |
| `infra/config_bucket.tf`, `bootstrap.tf` | Rendered configs, WebAdmin password, user data |
| `infra/logging_bucket.tf` | CloudFront logs bucket |
| `infra/backup.tf` | Backup vault, plan, selection, role |
| `infra/alerts.tf` | SNS topic, instance and database alarms |
| `infra/canary.tf`, `canary_iam.tf` | Synthetics canary, its alarm and role |
| `infra/cert_cloudfront_dns/` | Per-domain certificate, distribution, policies, DNS records |
| `infra/templates/bootstrap.sh.tftpl` | Instance bootstrap |
| `infra/templates/httpd_config.conf.tftpl`, `vhconf.conf.tftpl`, `admin_config.conf.tftpl` | OpenLiteSpeed server, virtual host and WebAdmin configs |
| `infra/templates/canary.js` | Canary script |

Outputs: `webserver_public_ip`, `webserver_public_dns`, `db_endpoint`, `db_master_secret_arn`,
`fsx_file_system_id`, `fsx_dns_name`, `media_buckets`, `backup_vault_name`, `alerts_topic_arn`,
`ols_admin_password_parameter`.

## Related projects

- [bugfloyd/aws-ols-mariadb-ami](https://github.com/bugfloyd/aws-ols-mariadb-ami) — Packer and
  Ansible build for the AMI. Use `-var profile=web` for this project; the `standalone` profile
  builds the self-contained image the AMI post describes.
- [bugfloyd/ols-wp-backup](https://github.com/bugfloyd/ols-wp-backup) — server-level backup
  scripts for the `standalone` profile. From the Stateless stage on, RDS automated backups and AWS
  Backup replace them.
