// Source-only candidate. Publication and runtime admission require independent review.
import { writeFileSync } from 'node:fs';

const FILE = '/work/sdk/tests/client.test.ts';
const LIMIT = 1024 * 1024;
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const errorRecord = (error) => ({
  name: String(error?.name ?? ''),
  message: String(error?.message ?? error),
  stack: String(error?.stack ?? ''),
});

export default class HostedBaselineReporter {
  constructor() {
    this.evidence = { schema: 1, init: 0, selection: 0, completion: 0, flags: [] };
  }

  fail(reason) {
    this.evidence.flags.push(reason);
  }

  observe(stage) {
    if (!this.ctx) throw new Error('missing reporter context');
    const record = {
      cancelling: this.ctx.isCancelling,
      restarts: this.ctx.restartsCount,
      errors: this.ctx.state.getUnhandledErrors().map(errorRecord),
    };
    if (record.cancelling !== false) this.fail(`${stage}:cancellation`);
    if (record.restarts !== this.evidence.initialRestarts) this.fail(`${stage}:restart`);
    if (record.errors.length) this.fail(`${stage}:unhandled-errors`);
    return record;
  }

  onInit(ctx) {
    this.ctx = ctx;
    this.evidence.init += 1;
    if (this.evidence.init !== 1) throw new Error('duplicate reporter initialization');
    this.evidence.initialRestarts = ctx.restartsCount;
    // Copy primitives now: close() can clear ctx.server before process exit.
    const config = ctx.config;
    this.evidence.settings = {
      root: config.root,
      environment: config.environment,
      globals: config.globals,
      include: [...config.include],
      cache: config.cache,
      viteRoot: ctx.server.config.root,
      viteCache: ctx.server.config.cacheDir,
      configFile: ctx.server.config.configFile,
      watch: config.watch,
      retry: config.retry,
      bail: config.bail,
      // segfaultRetry is a CLI-wrapper option, not reliably a resolved config field.
      ignoreUnhandledErrors: config.dangerouslyIgnoreUnhandledErrors === true,
      coverage: config.coverage.enabled,
      browser: config.browser.enabled,
      testNamePattern: config.testNamePattern ? String(config.testNamePattern) : null,
    };
    process.once('exit', (code) => {
      try {
        this.evidence.exit = { code, ...this.observe('exit') };
        if (code !== 1) this.fail('unexpected-exit-code');
        if (this.evidence.selection !== 1 || this.evidence.completion !== 1)
          this.fail('incomplete-hooks');
        const bytes = JSON.stringify(this.evidence);
        if (Buffer.byteLength(bytes) > LIMIT) throw new Error('envelope exceeds 1 MiB');
        writeFileSync('/reports/harness.json', bytes, { flag: 'wx', mode: 0o600 });
      } catch (error) {
        // Never turn missing final evidence into RED. Do not swallow runtime exceptions.
        process.stderr.write(`HARNESS_REPORT_WRITE_FAILURE: ${String(error)}\n`);
        process.exitCode = 2;
      }
    });
    ctx.onServerRestart(() => this.fail('server-restart'));
    ctx.onCancel(() => this.fail('cancel-listener'));
    // The cancel listener is supplementary: runFiles clears it before pool execution.
    const expected = {
      root: '/work/sdk', environment: 'happy-dom', globals: false,
      include: ['tests/**/*.test.ts'], cache: false,
      viteRoot: '/work/sdk', viteCache: '/cache/vite',
      configFile: '/cache/config/vitest.config.mjs', watch: false,
      retry: 0, bail: 0, ignoreUnhandledErrors: false,
      coverage: false, browser: false, testNamePattern: null,
    };
    if (!equal(this.evidence.settings, expected)) {
      this.fail('resolved-settings-mismatch');
      throw new Error('resolved settings violate frozen config contract');
    }
  }

  onPathsCollected(paths) {
    this.evidence.selection += 1;
    this.evidence.paths = [...paths];
    if (this.evidence.selection !== 1 || !equal(paths, [FILE])) {
      this.fail('pre-pool-selection');
      throw new Error('exact pre-pool selection required');
    }
  }

  onFinished(files, errors) {
    this.evidence.completion += 1;
    this.evidence.finished = this.observe('completion');
    if (!Array.isArray(errors)) throw new Error('missing completion error array');
    this.evidence.finished.suppliedErrors = errors.map(errorRecord);
    if (errors.length || this.evidence.completion !== 1) this.fail('completion-invalid');
    this.evidence.files = files.map((file) => file.filepath);
    if (!equal(this.evidence.files, [FILE])) this.fail('completion-selection');
    this.evidence.tasks = [];
    const visit = (task, parents) => {
      const result = task.result;
      if (task.type === 'test') {
        this.evidence.tasks.push({
          name: task.name, parents, mode: task.mode, state: result?.state,
          retryCount: result?.retryCount ?? 0,
          repeatCount: result?.repeatCount ?? 0,
          hooks: result?.hooks ?? {},
          errors: (result?.errors ?? []).map(errorRecord),
        });
      } else {
        if (result?.errors?.length) this.fail(`suite-error:${task.name}`);
        if (Object.values(result?.hooks ?? {}).some((state) => state !== 'pass'))
          this.fail(`suite-hook:${task.name}`);
        for (const child of task.tasks ?? []) visit(child, [...parents, task.name]);
      }
    };
    for (const file of files) visit(file, []);
    // JSON reporter runs concurrently. No reading its artifact here.
  }

  onProcessTimeout() { this.fail('process-timeout'); }
  onServerRestart() { this.fail('reporter-server-restart'); }
  onWatcherRerun() { this.fail('watcher-rerun'); }
}
