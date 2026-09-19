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
