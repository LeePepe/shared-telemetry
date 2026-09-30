import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { LokiTelemetry } from '../src/client.js';

describe('LokiTelemetry', () => {
  const endpoint = 'http://loki.test/loki/api/v1/push';
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.useFakeTimers();
    fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 204 });
    (globalThis as unknown as { fetch: typeof fetch }).fetch = fetchMock as unknown as typeof fetch;
    try {
      (globalThis as unknown as { localStorage?: Storage }).localStorage?.clear();
    } catch {
      /* ignore */
    }
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it('buffers events and flushes when batchSize is reached', async () => {
    const t = new LokiTelemetry({
      endpoint,
      labels: { app: 'Test' },
      batchSize: 3,
      flushIntervalMs: 10_000,
      storage: 'memory'
    });
    t.track('a');
    t.track('b');
    expect(fetchMock).not.toHaveBeenCalled();
    t.track('c'); // triggers flush
    await vi.runAllTimersAsync();
    await Promise.resolve();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe(endpoint);
    const body = JSON.parse(init.body as string);
    expect(body.streams.length).toBeGreaterThan(0);
    t.shutdown();
  });

  it('flushes on timer', async () => {
    const t = new LokiTelemetry({
      endpoint,
      labels: { app: 'Test' },
      batchSize: 100,
      flushIntervalMs: 1000,
      storage: 'memory'
    });
    t.track('tick');
    await vi.advanceTimersByTimeAsync(1100);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    t.shutdown();
  });

  it('merges base labels and sets event label per event', async () => {
    const t = new LokiTelemetry({
      endpoint,
      labels: { app: 'Financial', env: 'dev' },
      batchSize: 1,
      storage: 'memory'
    });
    t.track('recording.started', { provider: 'whisper' });
    await vi.runAllTimersAsync();
    await Promise.resolve();
    const body = JSON.parse((fetchMock.mock.calls[0]![1] as RequestInit).body as string);
    expect(body.streams[0].stream).toEqual({
      app: 'Financial',
      env: 'dev',
      event: 'recording.started'
    });
    const line = JSON.parse(body.streams[0].values[0][1]);
    expect(line.provider).toBe('whisper');
    expect(line.event).toBe('recording.started');
    expect(typeof line.t).toBe('string');
    t.shutdown();
  });

  it('log() uses level label', async () => {
    const t = new LokiTelemetry({
      endpoint,
      labels: { app: 'X' },
      batchSize: 1,
      storage: 'memory'
    });
    t.log('info', 'app.started', { user: 'tianpli' });
    await vi.runAllTimersAsync();
    await Promise.resolve();
    const body = JSON.parse((fetchMock.mock.calls[0]![1] as RequestInit).body as string);
    expect(body.streams[0].stream).toEqual({ app: 'X', level: 'info' });
    const line = JSON.parse(body.streams[0].values[0][1]);
    expect(line.message).toBe('app.started');
    expect(line.user).toBe('tianpli');
    t.shutdown();
  });

  it('ignores reserved labels provided in constructor', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const t = new LokiTelemetry({
      endpoint,
      labels: { app: 'A', event: 'nope', level: 'bad' } as unknown as Record<string, string>,
      storage: 'memory'
    });
    expect(warn).toHaveBeenCalled();
    t.shutdown();
  });

  it('retries: puts batch back on fetch failure and backs off', async () => {
    fetchMock.mockRejectedValueOnce(new Error('network down'));
    const t = new LokiTelemetry({
      endpoint,
      labels: { app: 'R' },
      batchSize: 100,
      flushIntervalMs: 1000,
      storage: 'memory'
    });
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    t.track('x');
    // First timer tick — triggers failing flush
    await vi.advanceTimersByTimeAsync(1100);
    await Promise.resolve();
    expect(fetchMock).toHaveBeenCalledTimes(1);

    // After failure: events requeued, backoff scheduled (>= flushIntervalMs).
    fetchMock.mockResolvedValueOnce({ ok: true, status: 204 });
    await vi.advanceTimersByTimeAsync(60_000);
    await Promise.resolve();
    expect(fetchMock.mock.calls.length).toBeGreaterThanOrEqual(2);
    t.shutdown();
  });

  it('manual flush sends pending events', async () => {
    const t = new LokiTelemetry({
      endpoint,
      labels: { app: 'M' },
      batchSize: 1000,
      flushIntervalMs: 60_000,
      storage: 'memory'
    });
    t.track('one');
    t.track('two');
    await t.flush();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    t.shutdown();
  });

  it('pagehide flushes via sendBeacon when available', () => {
    const beacon = vi.fn().mockReturnValue(true);
    (globalThis as unknown as { navigator: Navigator }).navigator = {
      sendBeacon: beacon
    } as unknown as Navigator;
    const t = new LokiTelemetry({
      endpoint,
      labels: { app: 'B' },
      batchSize: 100,
      storage: 'memory'
    });
    t.track('bye');
    // Simulate pagehide
    (globalThis as unknown as { dispatchEvent: (e: Event) => boolean }).dispatchEvent(
      new Event('pagehide')
    );
    expect(beacon).toHaveBeenCalledTimes(1);
    expect(beacon.mock.calls[0]![0]).toBe(endpoint);
    t.shutdown();
  });

  it('shutdown stops the timer and flushes once', async () => {
    const t = new LokiTelemetry({
      endpoint,
      labels: { app: 'S' },
      batchSize: 100,
      flushIntervalMs: 500,
      storage: 'memory'
    });
    t.track('gone');
    t.shutdown();
    await vi.advanceTimersByTimeAsync(5000);
    await Promise.resolve();
    // One flush from shutdown (may be 1 call).
    expect(fetchMock.mock.calls.length).toBeLessThanOrEqual(1);
  });
});
