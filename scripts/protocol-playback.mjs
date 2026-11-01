// Only numeric media telemetry leaves the disposable browser. Never export src,
// manifests, segment URLs, headers, cookies or signed playback tokens.
export function installPlaybackObserver() {
  const state = window.__rvPlayback = { first_frame_ms: null, presented_frames: 0,
    rebuffer_count: 0, rebuffer_ms: 0, waiting_since: null, media_errors: [],
    resolutions: [], ad_observed: false };
  const watched = new WeakSet();
  const primary = () => [...document.querySelectorAll('video')].sort((a, b) =>
    b.getBoundingClientRect().width * b.getBoundingClientRect().height
    - a.getBoundingClientRect().width * a.getBoundingClientRect().height)[0];
  const endWait = () => {
    if (state.waiting_since != null) {
      state.rebuffer_ms += performance.now() - state.waiting_since;
      state.waiting_since = null;
    }
  };
  const attach = () => {
    for (const video of document.querySelectorAll('video')) {
      if (watched.has(video)) continue;
      watched.add(video);
      video.muted = true;
      const frame = () => {
        if (video === primary()) {
          state.first_frame_ms ??= performance.now();
          state.presented_frames++;
          // The compositor can present its last queued frame after "waiting".
          // Buffering ends only when future media is available again.
          if (video.readyState >= 3 && !video.paused) endWait();
          const resolution = `${video.videoWidth}x${video.videoHeight}`;
          if (state.resolutions.at(-1) !== resolution) state.resolutions.push(resolution);
        }
        video.requestVideoFrameCallback(frame);
      };
      if (video.requestVideoFrameCallback) video.requestVideoFrameCallback(frame);
      video.addEventListener('waiting', () => {
        if (video === primary() && state.first_frame_ms != null && !video.paused && state.waiting_since == null) {
          state.waiting_since = performance.now(); state.rebuffer_count++;
        }
      });
      video.addEventListener('error', () => state.media_errors.push(video.error?.code ?? 0));
      video.addEventListener('canplay', () => {
        video.muted = true;
        if (video.paused) video.play().catch(() => {});
      });
    }
  };
  new MutationObserver(attach).observe(document, { childList: true, subtree: true });
  document.addEventListener('DOMContentLoaded', attach);
  window.__rvPlaybackSnapshot = () => {
    attach();
    const video = primary();
    const text = document.body?.innerText ?? '';
    state.ad_observed ||= /\bAdvertisement\b|\bCommercial break\b|\bAd \d+ of \d+\b/i.test(text);
    if (!video) return { ...state, video_present: false };
    let buffered = 0;
    for (let i = 0; i < video.buffered.length; i++) {
      if (video.buffered.start(i) <= video.currentTime && video.currentTime <= video.buffered.end(i))
        buffered = video.buffered.end(i) - video.currentTime;
    }
    const quality = video.getVideoPlaybackQuality?.();
    return { ...state, rebuffer_ms: state.rebuffer_ms + (state.waiting_since == null ? 0 : performance.now() - state.waiting_since),
      video_present: true, media_time: video.currentTime, paused: video.paused,
      ended: video.ended, live: video.duration === Infinity, ready_state: video.readyState,
      width: video.videoWidth, height: video.videoHeight, buffered_seconds: buffered,
      total_frames: quality?.totalVideoFrames ?? null, dropped_frames: quality?.droppedVideoFrames ?? null };
  };
}

export async function measurePlayback(page, stream, emit) {
  const started = new Date().toISOString();
  const failures = {};
  page.on('requestfailed', request => {
    const code = request.failure()?.errorText?.match(/net::ERR_[A-Z_]+/)?.[0] ?? 'request_failed';
    failures[code] = (failures[code] ?? 0) + 1;
  });
  await page.addInitScript(installPlaybackObserver);
  const snapshot = () => page.evaluate(() => window.__rvPlaybackSnapshot?.());
  try {
    await page.goto(stream.url, { waitUntil: 'domcontentloaded', timeout: stream.startupMs });
    const rejects = page.getByRole('button', { name: /^Reject(?: all)?$/i });
    for (let i = 0; i < await rejects.count(); i++) {
      if (await rejects.nth(i).isVisible()) { await rejects.nth(i).click({ timeout: 3000 }); break; }
    }
    await page.waitForFunction(() => window.__rvPlayback?.first_frame_ms != null,
      null, { timeout: stream.startupMs });
  } catch (error) {
    return { kind: 'playback', site: stream.label, outcome: 'playback_start_failed',
      started_at: started, error: String(error.message).match(/net::ERR_[A-Z_]+/)?.[0] ?? error.name,
      resource_failures: failures };
  }
  const initial = await snapshot();
  if (stream.requireLive !== false && !initial.live)
    return { kind: 'playback', site: stream.label, outcome: 'not_live_video', started_at: started };
  const start = Date.now();
  const timeline = [];
  let last = initial;
  while (Date.now() - start < stream.seconds * 1000) {
    await new Promise(resolve => setTimeout(resolve, Math.min(1000, stream.seconds * 1000 - (Date.now() - start))));
    last = await snapshot();
    if (!last?.video_present) break;
    timeline.push({ seconds: (Date.now() - start) / 1000, media_time: last.media_time,
      width: last.width, height: last.height, ready_state: last.ready_state,
      paused: last.paused, buffered_seconds: last.buffered_seconds,
      total_frames: last.total_frames, dropped_frames: last.dropped_frames });
    if (timeline.length % 15 === 0) emit({ kind: 'playback_progress', site: stream.label,
      elapsed_seconds: Math.round((Date.now() - start) / 1000), resolution: `${last.width}x${last.height}` });
  }
  const observed = (Date.now() - start) / 1000;
  const presented = (last?.presented_frames ?? 0) - initial.presented_frames;
  const rebuffer = Math.max(0, (last?.rebuffer_ms ?? 0) - initial.rebuffer_ms);
  const dropped = last?.dropped_frames == null || initial.dropped_frames == null ? null
    : Math.max(0, last.dropped_frames - initial.dropped_frames);
  const total = last?.total_frames == null || initial.total_frames == null ? null
    : Math.max(0, last.total_frames - initial.total_frames);
  let outcome = 'ok';
  if (!last?.video_present || presented === 0 || observed < stream.seconds - .1) outcome = 'playback_incomplete';
  else if (last.media_errors.length) outcome = 'media_error';
  else if (last.ad_observed) outcome = 'advertisement_observed';
  else if (last.ended || last.paused) outcome = 'playback_stopped';
  return { kind: 'playback', site: stream.label, outcome, started_at: started,
    first_frame_ms: initial.first_frame_ms, observed_seconds: observed,
    media_advanced_seconds: last?.media_time - initial.media_time,
    presented_frames: presented, decoded_frames: total, dropped_frames: dropped,
    dropped_percent: total ? dropped / total * 100 : null,
    rebuffer_count: Math.max(0, (last?.rebuffer_count ?? 0) - initial.rebuffer_count),
    rebuffer_ms: rebuffer, rebuffer_percent: rebuffer / (observed * 10),
    resolutions: last?.resolutions ?? [], quality_selection: 'auto',
    ad_observed: last?.ad_observed ?? false, live: last?.live ?? false,
    media_errors: last?.media_errors ?? [], resource_failures: failures, timeline };
}
