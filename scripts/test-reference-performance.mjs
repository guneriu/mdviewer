// GHSA-gfr2-rv44-r23c: keep both CommonMark reference paths enabled.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import MarkdownIt from 'markdown-it';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

if (process.argv[2] === '--block-anchor-child') {
  const source = readFileSync(new URL('../web/renderer.js', import.meta.url), 'utf8');
  const helper = source.match(/^function blockEntries\(container\) \{[\s\S]*?^\}/m);
  assert.ok(helper, 'source-named blockEntries helper exists');
  const blockEntries = vm.runInNewContext(`${helper[0]}; blockEntries`);
  const md = new MarkdownIt({ html: false, linkify: false });
  const text = md.parse('```\n' + 'x'.repeat(1_000_000) + '\n```', {})[0].content;
  let reads = 0;
  const container = { children: [{ tagName: 'PRE', get textContent() { reads++; return text; } }] };
  const key = blockEntries(container)[0].key;
  assert.equal(reads, 1, 'one textContent read per block');
  const start = performance.now();
  for (let i = 0; i < 5; i++) {
    reads = 0;
    assert.equal(blockEntries(container)[0].key, key, 'stable block key');
    assert.equal(reads, 1, 'one cached textContent read per block');
  }
  console.log(JSON.stringify({ kind: 'isolated block hashing (not DOM/app performance)', bytes: text.length, calls: 5, ms: performance.now() - start }));
} else if (process.argv[2] === '--child') {
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
  const child = spawnSync(process.execPath, [import.meta.filename, '--block-anchor-child'], {
    encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024
  });
  assert.equal(child.error, undefined, `bounded block hashing: ${child.error}`);
  assert.equal(child.status, 0, child.stderr);
  const result = JSON.parse(child.stdout);
  assert.ok(result.ms < 4000, `unexpected pathological block hashing: ${child.stdout}`);
  console.log(JSON.stringify(result));
  console.log('PASS reference syntax, 6 advisory timing cases and 1 single-block hashing case (5s child timeout, 4s ceiling)');
}
