// GHSA-gfr2-rv44-r23c: keep both CommonMark reference paths enabled.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import MarkdownIt from 'markdown-it';

if (process.argv[2] === '--child') {
  const md = new MarkdownIt({ html: false, linkify: false });
  md.render('warmup');
  const kind = process.argv[3];
  const n = Number(process.argv[4]);
  const source = kind === 'title' ? '[a]: /u "' + 'x\n'.repeat(n) : '[' + 'a\n'.repeat(n);
  const start = performance.now();
  md.render(source);
  console.log(JSON.stringify({ kind, n, bytes: Buffer.byteLength(source), ms: performance.now() - start }));
} else {
  const md = new MarkdownIt();
  assert.match(md.render('[ok][a]\n\n[a]: /local "title"'), /href="\/local" title="title"/);
  for (const [kind, sizes] of [['title', [100000, 200000, 400000]], ['label', [5000, 10000, 20000]]]) {
    for (const n of sizes) {
      const child = spawnSync(process.execPath, [import.meta.filename, '--child', kind, String(n)], {
        encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024
      });
      assert.equal(child.error, undefined, `bounded ${kind}/${n}: ${child.error}`);
      assert.equal(child.status, 0, child.stderr);
      const result = JSON.parse(child.stdout);
      assert.ok(result.ms < 4000, `unexpected pathological reference render: ${child.stdout}`);
      console.log(JSON.stringify(result));
    }
  }
  console.log('PASS reference syntax and 6 bounded advisory timing cases (5s child timeout, 4s render ceiling)');
}
