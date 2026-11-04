import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const files = JSON.parse(readFileSync('/app/.himax-test-list.json', 'utf8'));
const result = spawnSync('pnpm', ['exec', 'vitest', 'run', ...files, '--maxWorkers=1', '--reporter=json', '--outputFile=/results/targeted-tests.json'], { cwd: '/app', stdio: 'inherit' });
process.exit(result.status ?? 1);
