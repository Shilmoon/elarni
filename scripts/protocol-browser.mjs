// Private, disposable Chromium; one job on stdin, sanitized JSONL on stdout.
import { createRequire } from 'node:module';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';
import { measurePlayback } from './protocol-playback.mjs';

const require = createRequire(import.meta.url);
let browser;
let stopping = false;
const emit = value => process.stdout.write(`${JSON.stringify(value)}\n`);
const errorCode = error => String(error?.message ?? error).match(/net::ERR_[A-Z_]+/)?.[0]
  ?? (error?.name === 'TimeoutError' ? 'timeout' : 'browser_error');
async function bounded(promise, ms) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Object.assign(new Error('timeout'), { name: 'TimeoutError' })), ms);
    })]);
  } finally { clearTimeout(timer); }
}

async function stop() {
  stopping = true;
  const timer = setTimeout(() => process.exit(1), 5000);
  timer.unref();
  if (browser) await browser.close().catch(() => {});
}
process.on('SIGTERM', () => stop().finally(() => process.exit(1)));
process.on('SIGINT', () => stop().finally(() => process.exit(1)));

export function percentile(values, fraction) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  return sorted.length ? sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)] : null;
}

export async function measure(page, site, mode, options) {
  const requests = new Set();
  const failures = new Map();
  const httpErrors = new Map();
  const started = Date.now();
  let response;
  let navigationError;
  const onRequest = request => requests.add(request);
  const onFailed = request => failures.set(request, errorCode(request.failure()?.errorText));
  const onResponse = response => {
    if (response.status() >= 400) httpErrors.set(response.request(), response.status());
  };
  page.on('request', onRequest);
  page.on('requestfailed', onFailed);
  page.on('response', onResponse);
  try {
    response = mode === 'cold'
      ? await page.goto(site.url, { waitUntil: 'load', timeout: options.timeoutMs })
      : await page.reload({ waitUntil: 'load', timeout: options.timeoutMs });
  } catch (error) {
    navigationError = errorCode(error);
  }
  // A fixed observation window makes late paint/subresource samples comparable.
  await new Promise(resolve => setTimeout(resolve, options.observeMs));
  let metrics = {};
  let state = {};
  try {
    metrics = await bounded(page.evaluate(() => {
      const nav = performance.getEntriesByType('navigation')[0];
      const paints = performance.getEntriesByType('paint');
      const positive = value => value > 0 ? value : null;
      return {
        navigation_ttfb_ms: positive(nav?.responseStart),
        document_transfer_ms: nav ? positive(nav.responseEnd - nav.responseStart) : null,
        dom_content_loaded_ms: positive(nav?.domContentLoadedEventEnd),
        load_ms: positive(nav?.loadEventEnd),
        fcp_ms: paints.find(p => p.name === 'first-contentful-paint')?.startTime ?? null,
        observed_lcp_ms: window.__elarniLCP ?? null,
        document_bytes: nav?.encodedBodySize ?? 0,
        navigation_type: nav?.type ?? null,
      };
    }), 1500);
    state = await bounded(page.evaluate(selector => {
      const text = (document.body?.innerText ?? '').slice(0, 12000).toLowerCase();
      const title = document.title.toLowerCase();
      const consent = location.hostname.startsWith('consent.')
        || /before you continue to (youtube|google)/.test(text);
      const challenge = /just a moment|verify you are human|access denied|captcha|unusual traffic/.test(title)
        || !!document.querySelector('iframe[src*="recaptcha"], #challenge-running');
      return {
        consent, challenge,
        content_present: document.body != null && (document.body.innerText.trim().length > 40
          || document.querySelector('video, canvas, img') != null),
        selector_present: !selector || document.querySelector(selector) != null,
      };
    }, site.selector ?? null), 1500);
  } catch (error) {
    navigationError ??= errorCode(error);
  }
  // Never await request.response(): an unfinished navigation can remain pending
  // beyond its navigation timeout. Response events already supply the status.
  if (!response) {
    for (const request of requests) {
      try {
        if (request.isNavigationRequest() && request.frame() === page.mainFrame()) {
          response = request.existingResponse();
        }
      } catch { /* Detached frames have no usable response. */ }
    }
  }
  const timings = [...requests].map(request => {
    const t = request.timing();
    return {
      type: request.resourceType(),
      response_ms: t.responseStart >= 0 ? t.responseStart : null,
      wait_ms: t.responseStart >= 0 && t.requestStart >= 0 ? t.responseStart - t.requestStart : null,
      complete_ms: t.responseEnd >= 0 ? t.responseEnd : null,
    };
  });
  const status = response?.status() ?? null;
  let outcome = 'ok';
  if (navigationError) outcome = navigationError;
  else if (state.consent) outcome = 'consent_page';
  else if (state.challenge) outcome = 'challenge_page';
  else if (!status || status < 200 || status >= 400) outcome = 'http_error';
  else if (!state.content_present || !state.selector_present || metrics.fcp_ms == null) outcome = 'content_missing';
  const counts = values => Object.fromEntries([...new Set(values)].map(key => [key, values.filter(v => v === key).length]));
  const result = {
    kind: 'page', site: site.label, mode, outcome, http_status: status,
    started_at: new Date(started).toISOString(), elapsed_ms: Date.now() - started,
    observation_after_load_ms: options.observeMs, ...metrics,
    requests: requests.size, failed_requests: failures.size,
    http_error_requests: httpErrors.size,
    failure_codes: counts([...failures.values()]),
    http_errors: counts([...httpErrors.values()]),
    unfinished_requests: timings.filter(t => t.complete_ms == null).length,
    resource_response_p95_ms: percentile(timings.map(t => t.response_ms), .95),
    resource_wait_over_3s: timings.filter(t => t.wait_ms >= 3000).length,
    // No URLs, headers, bodies, cookies, signed media URLs or browser profiles are exported.
  };
  page.off('request', onRequest);
  page.off('requestfailed', onFailed);
  page.off('response', onResponse);
  return result;
}

async function main(job) {
  const playwright = job.playwrightModule ? require(job.playwrightModule) : require('playwright');
  if (!/^socks5:\/\/127\.0\.0\.1:\d+$/.test(job.proxy)) throw new Error('invalid_proxy');
  browser = await playwright.chromium.launch({
    headless: !job.visible,
    ...(job.executable ? { executablePath: job.executable } : { channel: 'chrome' }),
    proxy: { server: job.proxy, bypass: '<-loopback>' },
    args: ['--disable-quic'],
  });
  if (stopping) { await browser.close(); return; }
  emit({ kind: 'browser_started', version: browser.version() });
  try {
    if (job.stream) {
      const context = await browser.newContext({ viewport: { width: 1365, height: 900 },
        locale: 'en-US', serviceWorkers: 'block', acceptDownloads: false });
      try {
        await context.addInitScript(() => {
          for (const key of ['RTCPeerConnection', 'webkitRTCPeerConnection'])
            Object.defineProperty(window, key, { value: undefined, configurable: false });
        });
        emit(await measurePlayback(await context.newPage(), job.stream, emit));
      } finally { await context.close(); }
    }
    for (const site of job.sites) {
      if (stopping) break;
      const context = await browser.newContext({
        viewport: { width: 1365, height: 900 }, locale: 'en-US',
        serviceWorkers: 'block', acceptDownloads: false,
      });
      try {
        await context.addInitScript(() => {
          // WebRTC UDP does not use an HTTP/SOCKS browser proxy. This is a web
          // page benchmark, so disallow that separate transport in every frame.
          for (const key of ['RTCPeerConnection', 'webkitRTCPeerConnection']) {
            Object.defineProperty(window, key, { value: undefined, configurable: false });
          }
          window.__elarniLCP = null;
          new PerformanceObserver(list => {
            for (const entry of list.getEntries()) window.__elarniLCP = entry.startTime;
          }).observe({ type: 'largest-contentful-paint', buffered: true });
        });
        const page = await context.newPage();
        for (const mode of ['cold', 'warm']) {
          if (stopping) break;
          const sample = await measure(page, site, mode, job);
          emit(sample);
          if (mode === 'cold' && sample.outcome === 'consent_page') {
            const reject = page.getByRole('button', { name: /^Reject all$/i });
            if (await reject.count() === 1 && await reject.isVisible()) {
              try {
                await reject.click({ timeout: job.timeoutMs });
                await page.waitForLoadState('load', { timeout: job.timeoutMs });
                // Keep the consent landing separate. This reload has cookies
                // and may have cached assets; it is never relabeled as cold.
                emit(await measure(page, site, 'after_consent', job));
              } catch (error) {
                emit({ kind: 'consent_action', site: site.label, outcome: errorCode(error) });
              }
            }
          }
        }
      } finally {
        await context.close();
      }
    }
  } finally {
    await browser.close();
    browser = null;
  }
  emit({ kind: 'browser_done' });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  let admitted = false;
  input.on('line', line => {
    if (admitted) return;
    admitted = true;
    Promise.resolve().then(() => main(JSON.parse(line))).then(
      () => process.exit(0),
      error => { emit({ kind: 'browser_error', outcome: errorCode(error) }); stop().finally(() => process.exit(1)); },
    );
  });
  input.on('close', () => stop().finally(() => process.exit(1)));
}
