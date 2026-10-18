import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const html = readFileSync(new URL('../web/index.html', import.meta.url), 'utf8');
const source = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)]
  .map((match) => match[1])
  .find((script) => script.includes('window.fctvAttachHls ='));
assert.ok(source, 'HLS bridge script must be present');

function player({ native = true } = {}) {
  let now = 0;
  let nextId = 0;
  let refreshes = 0;
  const timers = new Map();
  const listeners = new Map();
  const instances = [];
  const setTimer = (fn, delay, repeat = false) => {
    const id = ++nextId;
    timers.set(id, { fn, at: now + delay, delay, repeat });
    return id;
  };
  const video = {
    currentTime: 10, paused: false, readyState: 4, error: null,
    style: {}, reloads: 0, seeks: 0, src: '',
    seekable: { length: 1, start: () => 0, end: () => 60 },
    canPlayType: () => native ? 'probably' : '',
    setAttribute() {}, removeAttribute() {},
    load() { this.reloads++; },
    play() { this.paused = false; return Promise.resolve(); },
    addEventListener(name, fn) {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name).add(fn);
    },
    removeEventListener(name, fn) { listeners.get(name)?.delete(fn); },
  };
  class Hls {
    static Events = { MANIFEST_PARSED: 'manifest', ERROR: 'error' };
    static ErrorTypes = { NETWORK_ERROR: 'network', MEDIA_ERROR: 'media' };
    static isSupported() { return true; }
    constructor(config) { this.config = config; this.events = new Map(); this.starts = 0; instances.push(this); }
    on(name, fn) { this.events.set(name, fn); }
    loadSource() {}
    attachMedia() {}
    startLoad() { this.starts++; }
    destroy() { this.destroyed = true; }
    get liveSyncPosition() { return 42; }
  }
  const window = { Hls, fctvOnStreamNeedsRefresh() { refreshes++; } };
  vm.runInNewContext(source, {
    window, document: {}, console: { debug() {} },
    setTimeout: (fn, delay) => setTimer(fn, delay),
    clearTimeout: (id) => timers.delete(id),
    setInterval: (fn, delay) => setTimer(fn, delay, true),
    clearInterval: (id) => timers.delete(id),
  });
  function emit(name) { for (const fn of [...(listeners.get(name) ?? [])]) fn(); }
  void window.fctvAttachHls(video, 'https://example.com/live.m3u8');
  const initialReloads = video.reloads;
  emit('playing');
  function advance(ms, { moving = false, event } = {}) {
    for (let elapsed = 0; elapsed < ms; elapsed += 250) {
      now += 250;
      if (moving) {
        video.currentTime += 0.25;
        emit('timeupdate');
      }
      if (event) emit(event);
      for (const [id, timer] of [...timers]) {
        if (!timers.has(id) || timer.at > now) continue;
        if (timer.repeat) timer.at += timer.delay;
        else timers.delete(id);
        timer.fn();
      }
    }
  }
  return { video, window, instances, emit, advance, initialReloads,
    get refreshes() { return refreshes; } };
}

test('three minutes of normal timeupdate events never reload native HLS', () => {
  const p = player();
  p.advance(180000, { moving: true });
  assert.equal(p.video.reloads, p.initialReloads);
});

test('normal playback never seeks to live or restarts hls.js', () => {
  const p = player({ native: false });
  p.advance(180000, { moving: true });
  assert.equal(p.instances.length, 1);
  assert.equal(p.instances[0].starts, 0);
  assert.equal(p.video.currentTime, 190);
});

test('a frozen native playback clock triggers a reload', () => {
  const p = player();
  p.advance(20000);
  assert.ok(p.video.reloads > p.initialReloads);
});

test('repeated waiting events cannot postpone recovery forever', () => {
  const p = player();
  p.video.readyState = 2;
  p.advance(20000, { event: 'waiting' });
  assert.ok(p.video.reloads > p.initialReloads);
});

test('resuming just before the stall deadline preserves the healthy buffer', () => {
  const p = player();
  p.emit('waiting');
  p.advance(7750);
  p.advance(2250, { moving: true });
  assert.equal(p.video.reloads, p.initialReloads);
});

test('a brief buffering event that recovers without playing does not reload', () => {
  const p = player();
  p.video.readyState = 2;
  p.emit('waiting');
  p.advance(4000);
  p.video.readyState = 4;
  p.advance(30000, { moving: true });
  assert.equal(p.video.reloads, p.initialReloads);
});

test('hls.js escalates when the clock stays frozen despite a healthy readyState', () => {
  const p = player({ native: false });
  p.advance(30000);
  assert.ok(p.instances.length > 1);
});

test('user pause suppresses automatic recovery', () => {
  const p = player();
  p.video.paused = true;
  p.emit('pause');
  p.advance(30000, { event: 'waiting' });
  assert.equal(p.video.reloads, p.initialReloads);
});

test('destroying a session cancels its pending recoveries', () => {
  const p = player();
  p.emit('waiting');
  p.window.fctvDestroyHls();
  p.advance(30000);
  assert.equal(p.video.reloads, p.initialReloads);
});
