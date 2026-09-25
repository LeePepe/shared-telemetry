import { LokiTelemetry, PersistentQueue, buildPushBody, STORAGE_KEY } from '@leepepe/loki-web';
import type { TelemetryEvent, LokiPushBody } from '@leepepe/loki-web';

function check(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const event: TelemetryEvent = {labels: {app: 'synthetic'}, tsNanos: '1000000', line: '{"event":"synthetic.completed"}'};
let dropped = 0;
const queue = new PersistentQueue(2, 'memory', count => { dropped += count; });
queue.enqueue(event);
queue.enqueue(event);
queue.enqueue(event);
check(queue.size() === 2 && dropped === 1, 'bounded queue overflow contract');
check(buildPushBody(queue.snapshot()).streams[0]?.values.length === 2, 'public push body');
check(STORAGE_KEY === 'loki-web:queue', 'storage key contract');

let missingEndpointRejected = false;
try { new LokiTelemetry({endpoint: ''}); } catch { missingEndpointRejected = true; }
check(missingEndpointRejected, 'missing endpoint must reject');

const originalFetch = globalThis.fetch;
const sent: LokiPushBody[] = [];
let rejectNext = true;
globalThis.fetch = async (url, options) => {
  check(url === 'https://synthetic.invalid/loki/api/v1/push', 'no unexpected endpoint');
  check(new Headers(options?.headers).get('Authorization') === 'Bearer synthetic-only', 'Bearer wiring');
  sent.push(JSON.parse(String(options?.body)) as LokiPushBody);
  if (rejectNext) { rejectNext = false; return new Response(null, {status: 503}); }
  return new Response(null, {status: 204});
};
const client = new LokiTelemetry({endpoint: 'https://synthetic.invalid/loki/api/v1/push',
  token: 'synthetic-only', labels: {app: 'synthetic'}, storage: 'memory', flushIntervalMs: 3600000});
try {
  client.track('synthetic.completed', {duration_ms: 1});
  await client.flush();
  await client.flush();
  check(sent.length === 2, 'failed attempt must requeue for the next flush');
  const first = sent[0]?.streams[0];
  check(first?.stream.event === 'synthetic.completed', 'event label');
  check(JSON.parse(first.values[0]![1]).duration_ms === 1, 'synthetic body');
  check(JSON.stringify(sent[0]) === JSON.stringify(sent[1]), 'retry preserves queued payload');
  client.shutdown();
  client.track('synthetic.ignored');
  await client.flush();
  check(sent.length === 2, 'shutdown stops new events');
  console.log('WEB_CONSUMER_OK');
} finally {
  client.shutdown();
  globalThis.fetch = originalFetch;
}
