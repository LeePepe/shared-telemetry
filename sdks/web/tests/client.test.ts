import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { LokiTelemetry, type LokiPushBody, type TelemetryOptions } from '../src/index.js';

describe('LokiTelemetry', () => {
  const endpoint = 'http://loki.test/loki/api/v1/push';
  const success = { ok: true, status: 204 };
  const clients = new Set<LokiTelemetry>();
  const pendingResponses = new Set<() => void>();
  const restoreDescriptors: Array<() => void> = [];
  let fetchMock: ReturnType<typeof vi.fn>;
  let beacon: ReturnType<typeof vi.fn>;
  let lifecycle: EventTarget;
  let addListener: ReturnType<typeof vi.fn>;
  let removeListener: ReturnType<typeof vi.fn>;

  function createClient(options: TelemetryOptions): LokiTelemetry {
    const client = new LokiTelemetry(options);
    clients.add(client);
    return client;
  }

  function bodyAt(index: number): LokiPushBody {
    return JSON.parse((fetchMock.mock.calls[index]![1] as RequestInit).body as string);
  }

  function deferredResponse() {
    let resolve!: (value: typeof success) => void;
    let reject!: (reason: Error) => void;
    const promise = new Promise<typeof success>((res, rej) => {
      resolve = res;
      reject = rej;
    });
    const settle = () => resolve(success);
    pendingResponses.add(settle);
    return {
      promise,
      reject(reason: Error) {
        pendingResponses.delete(settle);
        reject(reason);
      }
    };
  }

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-01-01T00:00:00.000Z'));
    const values = new Map<string, string>();
    const storage: Storage = {
      get length() { return values.size; },
      clear: () => values.clear(),
      getItem: (key) => values.get(key) ?? null,
      key: (index) => [...values.keys()][index] ?? null,
      removeItem: (key) => { values.delete(key); },
      setItem: (key, value) => { values.set(key, String(value)); }
    };
    // Cover both lookup paths without ever reading or clearing real storage.
    for (const target of new Set<object>([globalThis, window])) {
      const descriptor = Object.getOwnPropertyDescriptor(target, 'localStorage');
      restoreDescriptors.push(() => {
        if (descriptor) Object.defineProperty(target, 'localStorage', descriptor);
        else Reflect.deleteProperty(target, 'localStorage');
      });
      Object.defineProperty(target, 'localStorage', { configurable: true, value: storage });
    }
    fetchMock = vi.fn().mockResolvedValue(success);
    beacon = vi.fn().mockReturnValue(true);
    vi.stubGlobal('fetch', fetchMock);
    vi.stubGlobal('navigator', { sendBeacon: beacon });
    // Exercise browser events on a fresh target; no listeners escape to the host.
    lifecycle = new EventTarget();
    addListener = vi.fn(lifecycle.addEventListener.bind(lifecycle));
    removeListener = vi.fn(lifecycle.removeEventListener.bind(lifecycle));
    vi.stubGlobal('addEventListener', addListener);
    vi.stubGlobal('removeEventListener', removeListener);
    vi.stubGlobal('dispatchEvent', lifecycle.dispatchEvent.bind(lifecycle));
  });

  afterEach(async () => {
    try {
      // Assertion failures can leave a controlled request inflight or a retry queued.
      // Complete those requests, then drain and stop clients while fakes still own I/O.
      fetchMock.mockReset().mockResolvedValue(success);
      for (const settle of pendingResponses) settle();
      pendingResponses.clear();
      await Promise.allSettled([...clients].map((client) => client.flush()));
      for (const client of clients) client.shutdown();
      await Promise.allSettled([...clients].map((client) => client.flush()));
    } finally {
      // Defensive cleanup also covers a regression in shutdown's listener removal.
      for (const [type, listener, options] of addListener.mock.calls) {
        lifecycle.removeEventListener(type, listener, options);
      }
      clients.clear();
      pendingResponses.clear();
      vi.clearAllTimers();
      vi.restoreAllMocks();
      vi.unstubAllGlobals();
      for (const restore of restoreDescriptors.reverse()) restore();
      restoreDescriptors.length = 0;
      vi.useRealTimers();
    }
  });

  it('buffers events and flushes when batchSize is reached', async () => {
    const t = createClient({
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
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await t.flush(); // joins the threshold-triggered request
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe(endpoint);
    const body = JSON.parse(init.body as string);
    expect(body.streams.length).toBeGreaterThan(0);
    t.shutdown();
  });

  it('flushes on timer', async () => {
    const t = createClient({
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
    const t = createClient({
      endpoint,
      labels: { app: 'Financial', env: 'dev' },
      batchSize: 1,
      storage: 'memory'
    });
    t.track('recording.started', { provider: 'synthetic-provider' });
    await t.flush();
    const body = JSON.parse((fetchMock.mock.calls[0]![1] as RequestInit).body as string);
    expect(body.streams[0].stream).toEqual({
      app: 'Financial',
      env: 'dev',
      event: 'recording.started'
    });
    const line = JSON.parse(body.streams[0].values[0][1]);
    expect(line.provider).toBe('synthetic-provider');
    expect(line.event).toBe('recording.started');
    expect(typeof line.t).toBe('string');
    t.shutdown();
  });

  it('log() uses level label', async () => {
    const t = createClient({
      endpoint,
      labels: { app: 'X' },
      batchSize: 1,
      storage: 'memory'
    });
    t.log('info', 'app.started', { user: 'synthetic-user' });
    await t.flush();
    const body = JSON.parse((fetchMock.mock.calls[0]![1] as RequestInit).body as string);
    expect(body.streams[0].stream).toEqual({ app: 'X', level: 'info' });
    const line = JSON.parse(body.streams[0].values[0][1]);
    expect(line.message).toBe('app.started');
    expect(line.user).toBe('synthetic-user');
    t.shutdown();
  });

  it('ignores reserved labels provided in constructor', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const t = createClient({
      endpoint,
      labels: { app: 'A', event: 'nope', level: 'bad' } as unknown as Record<string, string>,
      storage: 'memory'
    });
    expect(warn).toHaveBeenCalled();
    t.shutdown();
  });

  it('retries: puts batch back on fetch failure and backs off', async () => {
    const firstResponse = deferredResponse();
    fetchMock.mockReturnValueOnce(firstResponse.promise)
      .mockRejectedValueOnce(new Error('synthetic second failure'));
    const t = createClient({
      endpoint,
      labels: { app: 'R' },
      batchSize: 100,
      flushIntervalMs: 1000,
      storage: 'memory'
    });
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    t.track('x', { sequence: 1 });
    await vi.advanceTimersByTimeAsync(999);
    expect(fetchMock).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1); // first attempt at 1000ms
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const firstBody = bodyAt(0);
    expect(firstBody.streams).toHaveLength(1);
    expect(firstBody.streams[0]!.values).toHaveLength(1);

    await vi.advanceTimersByTimeAsync(500);
    const waitingFlush = t.flush(); // joins inflight work with an empty queue
    firstResponse.reject(new Error('synthetic first failure'));
    await waitingFlush; // failed at 1500ms: retry is due at 3500ms, not 2500ms
    await vi.advanceTimersByTimeAsync(500);
    t.track('x', { sequence: 2 }); // must not reset the pending retry deadline
    await vi.advanceTimersByTimeAsync(1499);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    const secondBody = bodyAt(1);
    expect(secondBody.streams).toHaveLength(1);
    expect(secondBody.streams[0]!.stream).toEqual({ app: 'R', event: 'x' });
    expect(secondBody.streams[0]!.values).toHaveLength(2);
    expect(secondBody.streams[0]!.values.slice(0, 1)).toEqual(firstBody.streams[0]!.values);
    expect(secondBody.streams[0]!.values.map(([, line]) => JSON.parse(line).sequence)).toEqual([1, 2]);

    await vi.advanceTimersByTimeAsync(500);
    t.track('x', { sequence: 3 });
    await vi.advanceTimersByTimeAsync(3499);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1); // second backoff doubles to 4000ms: 7500ms
    expect(fetchMock).toHaveBeenCalledTimes(3);
    const thirdBody = bodyAt(2);
    expect(thirdBody.streams).toHaveLength(1);
    expect(thirdBody.streams[0]!.stream).toEqual(secondBody.streams[0]!.stream);
    expect(thirdBody.streams[0]!.values).toHaveLength(3);
    expect(thirdBody.streams[0]!.values.slice(0, 2)).toEqual(secondBody.streams[0]!.values);
    expect(thirdBody.streams[0]!.values.map(([, line]) => JSON.parse(line).sequence)).toEqual([1, 2, 3]);

    await vi.advanceTimersByTimeAsync(500);
    t.track('recovered');
    await vi.advanceTimersByTimeAsync(499);
    expect(fetchMock).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(1); // success restores the 1000ms interval
    expect(fetchMock).toHaveBeenCalledTimes(4);
    expect(bodyAt(3).streams[0]!.stream.event).toBe('recovered');
    t.shutdown();
  });

  it('manual flush sends pending events', async () => {
    const t = createClient({
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
    const t = createClient({
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
    const t = createClient({
      endpoint,
      labels: { app: 'S' },
      batchSize: 100,
      flushIntervalMs: 500,
      storage: 'memory'
    });
    t.track('gone');
    expect(fetchMock).not.toHaveBeenCalled(); // explicitly the non-inflight case
    const registered = [...addListener.mock.calls];
    expect(registered.map(([type]) => type).sort()).toEqual(['pagehide', 'visibilitychange']);
    t.shutdown();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await t.flush(); // await the final attempt without advancing its former timer
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(bodyAt(0).streams).toHaveLength(1);
    expect(bodyAt(0).streams[0]!.stream).toEqual({ app: 'S', event: 'gone' });
    expect(bodyAt(0).streams[0]!.values).toHaveLength(1);
    expect(removeListener).toHaveBeenCalledTimes(2);
    for (const [type, listener] of registered) {
      expect(removeListener).toHaveBeenCalledWith(type, listener);
    }
    expect(vi.getTimerCount()).toBe(0);

    t.track('ignored.track');
    t.log('info', 'ignored.log');
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('hidden');
    globalThis.dispatchEvent(new Event('pagehide'));
    globalThis.dispatchEvent(new Event('visibilitychange'));
    t.shutdown(); // repeated shutdown must not send again
    await vi.advanceTimersByTimeAsync(5000);
    await t.flush();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(beacon).not.toHaveBeenCalled();
    expect(removeListener).toHaveBeenCalledTimes(2);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('flushes a below-threshold event on the next interval after an initially empty tick', async () => {
    const t = createClient({ endpoint, batchSize: 100, flushIntervalMs: 1000, storage: 'memory' });
    await vi.advanceTimersByTimeAsync(1000);
    expect(fetchMock).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(100);
    t.track('after.initial.idle', { count: 1 });
    expect(fetchMock).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(899);
    expect(fetchMock).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const body = bodyAt(0);
    expect(body.streams).toHaveLength(1);
    expect(body.streams[0]!.stream).toEqual({ event: 'after.initial.idle' });
    expect(body.streams[0]!.values).toHaveLength(1);
    expect(JSON.parse(body.streams[0]!.values[0]![1])).toMatchObject({ event: 'after.initial.idle', count: 1 });
  });

  it('flushes a new small batch after a successful send followed by an empty tick', async () => {
    const t = createClient({ endpoint, batchSize: 100, flushIntervalMs: 1000, storage: 'memory' });
    t.track('before.idle');
    await vi.advanceTimersByTimeAsync(1000);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(bodyAt(0).streams[0]!.stream).toEqual({ event: 'before.idle' });
    await vi.advanceTimersByTimeAsync(1000); // empty tick after success
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(100);
    t.track('after.success.idle', { count: 2 });
    await vi.advanceTimersByTimeAsync(899);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    const body = bodyAt(1);
    expect(body.streams).toHaveLength(1);
    expect(body.streams[0]!.stream).toEqual({ event: 'after.success.idle' });
    expect(body.streams[0]!.values).toHaveLength(1);
    expect(JSON.parse(body.streams[0]!.values[0]![1])).toMatchObject({ event: 'after.success.idle', count: 2 });
  });

  it('preserves Financial-shaped labels and track/log performance properties through the root export', async () => {
    const labels = { app: 'synthetic-financial', env: 'test', platform: 'web' };
    const t = createClient({ endpoint, labels, batchSize: 20, flushIntervalMs: 5000 });
    // Synthetic action/count/duration only; stream is a line property, not a label.
    t.track('synthetic.action', { stream: 'events', action: 'synthetic-action', count: 2 });
    t.log('performance', 'synthetic.render', { stream: 'performance', duration_ms: 12, count: 3 });
    expect(fetchMock).not.toHaveBeenCalled();
    await t.flush();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe(endpoint);
    expect(init.method).toBe('POST');
    expect(init.headers).toEqual({ 'Content-Type': 'application/json' });
    const body = bodyAt(0);
    expect(body.streams).toHaveLength(2);
    const [eventStream, performanceStream] = body.streams;
    expect(eventStream!.stream).toEqual({ ...labels, event: 'synthetic.action' });
    expect(performanceStream!.stream).toEqual({ ...labels, level: 'performance' });
    expect(eventStream!.values).toHaveLength(1);
    expect(performanceStream!.values).toHaveLength(1);
    expect(JSON.parse(eventStream!.values[0]![1])).toEqual({
      t: '2026-01-01T00:00:00.000Z', event: 'synthetic.action',
      stream: 'events', action: 'synthetic-action', count: 2
    });
    expect(JSON.parse(performanceStream!.values[0]![1])).toEqual({
      t: '2026-01-01T00:00:00.000Z', level: 'performance', message: 'synthetic.render',
      stream: 'performance', duration_ms: 12, count: 3
    });
  });
});
