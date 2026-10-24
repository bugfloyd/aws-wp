// Viewer response: what the browser is told, as opposed to what CloudFront keeps.
//
// The origin marks cacheable pages with s-maxage, stale-while-revalidate and
// stale-if-error, and those are for CloudFront. Browsers honour the stale
// directives too, and a browser showing its own day-old copy of a page - the
// anonymous version after logging in, say - is exactly what the edge rules
// exist to prevent. So those pages reach the browser as no-cache: kept, but
// checked with CloudFront on every visit, which answers from its own cache.
//
// Static files carry no s-maxage and keep their browser caching.

function handler(event) {
    var response = event.response;
    var cacheControl = response.headers['cache-control'];

    if (cacheControl && cacheControl.value.indexOf('s-maxage') !== -1) {
        response.headers['cache-control'] = { value: 'no-cache' };
    }

    return response;
}
