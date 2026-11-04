import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const files = JSON.parse(readFileSync('/app/.himax-test-list.json', 'utf8'));
const result = spawnSync('pnpm', ['exec', 'vitest', 'run', ...files, '--maxWorkers=1', '--reporter=default', '--reporter=json', '--outputFile.json=/results/targeted-tests.json'], { cwd: '/app', stdio: 'inherit' });
try {
  const report = JSON.parse(readFileSync('/results/targeted-tests.json', 'utf8'));
  const failures = (report.testResults || []).flatMap(suite => [
    ...(suite.message ? [{ file: suite.name, message: suite.message }] : []),
    ...(suite.assertionResults || []).filter(test => test.status === 'failed').map(test => ({ file: suite.name, test: test.fullName, messages: test.failureMessages })),
  ]);
  let summary = JSON.stringify({ passed: report.numPassedTests, failed: report.numFailedTests, pending: report.numPendingTests, failures });
  const url = process.env.HIMAX_GEO_PATCH_TEST_PG;
  if (url) { summary = summary.replaceAll(url, '[EPHEMERAL_TEST_DATABASE]'); const password = new URL(url).password; if (password) summary = summary.replaceAll(password, '[EPHEMERAL_PASSWORD]'); }
  process.stdout.write(summary + '\n');
} catch { process.stderr.write('Structured test report unavailable; see default reporter output.\n'); }
process.exit(result.status ?? 1);
