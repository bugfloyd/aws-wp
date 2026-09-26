// Checks the origin, not the cache.
//
// The failure this exists to catch: OpenLiteSpeed comes up misconfigured while
// the instance itself is perfectly healthy. CloudFront keeps serving the front
// page from cache, so every homepage returns 200 and an EC2 status-check alarm
// stays green, while everything dynamic returns 5xx. Checking "/" would have
// reported all three sites healthy throughout a real four-minute outage.
//
// wp-login.php is the cheapest page that cannot be served from cache and that
// exercises the whole path: PHP runs, and WordPress reaches the database to
// render the form. A 200 whose body has no login form means WordPress answered
// with something that is not WordPress, which is also a failure.
const synthetics = require('Synthetics');
const log = require('SyntheticsLogger');

const checkOrigin = async function () {
  // Only the metrics something reads. The runtime always sends Duration and
  // SuccessPercent, for this canary and account-wide; the alarm reads this
  // canary's SuccessPercent, and the per-site step metrics show which site
  // failed. The response-code and failure counts, per canary and again
  // account-wide, only restate the pass rate for three requests a run, and
  // every distinct metric past the account's free ten costs $0.30 a month.
  synthetics.getConfiguration().setConfig({
    failedCanaryMetric: false,
    failedRequestsMetric: false,
    _2xxMetric: false,
    _4xxMetric: false,
    _5xxMetric: false,
    aggregatedFailedCanaryMetric: false,
    aggregatedFailedRequestsMetric: false,
    aggregated2xxMetric: false,
    aggregated4xxMetric: false,
    aggregated5xxMetric: false,
  });

  const domains = process.env.DOMAINS.split(',').filter(Boolean);

  for (const domain of domains) {
    await synthetics.executeHttpStep(
      `origin ${domain}`,
      {
        hostname: domain,
        method: 'GET',
        path: '/wp-login.php',
        port: 443,
        protocol: 'https:',
        headers: { 'User-Agent': 'CloudWatchSynthetics/origin-health' },
      },
      async (res) => {
        return new Promise((resolve, reject) => {
          if (res.statusCode !== 200) {
            reject(new Error(`${domain}: HTTP ${res.statusCode}`));
            return;
          }

          let body = '';
          res.on('data', (chunk) => { body += chunk; });
          res.on('end', () => {
            if (!body.includes('user_login')) {
              reject(new Error(`${domain}: 200 but no login form - WordPress did not render`));
              return;
            }
            log.info(`${domain}: origin healthy`);
            resolve();
          });
        });
      }
    );
  }
};

exports.handler = async () => {
  return await checkOrigin();
};
