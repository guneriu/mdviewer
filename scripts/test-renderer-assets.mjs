import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

process.chdir(fileURLToPath(new URL('../', import.meta.url)));
const manifest = JSON.parse(await readFile('vendor-manifest.json', 'utf8'));
const lock = JSON.parse(await readFile('package-lock.json', 'utf8'));
const paths = [...manifest.assets.map(asset => asset.path), 'vendor-manifest.json', 'THIRD_PARTY_NOTICES.md'];
const original = new Map(await Promise.all(paths.map(async path => [path, await readFile(path)])));
for (const asset of manifest.assets) {
  const bytes = original.get(asset.path);
  assert.equal(bytes.length, asset.bytes, asset.path);
  assert.equal(createHash('sha256').update(bytes).digest('hex'), asset.sha256, asset.path);
}
const production = Object.entries(lock.packages).filter(([location, entry]) => location && !entry.dev);
assert.equal(manifest.packages.length, production.length);
const notices = original.get('THIRD_PARTY_NOTICES.md').toString('utf8');
for (const [location, entry] of production) {
  const name = location.replace(/^node_modules\//, '');
  const inventory = manifest.packages.find(pkg => pkg.name === name);
  assert.ok(inventory, name);
  for (const [field, value] of Object.entries({ version: entry.version, source: entry.resolved, integrity: entry.integrity, license: entry.license })) {
    assert.equal(inventory[field], value, `${name}: ${field}`);
  }
  assert.match(inventory.source, /^https:\/\/registry\.npmjs\.org\//);
  assert.match(inventory.integrity, /^sha512-/);
  assert.ok(inventory.licenseFiles.length > 0);
  for (const license of inventory.licenseFiles) {
    const text = await readFile(`${location}/${license.name}`, 'utf8');
    assert.equal(createHash('sha256').update(text).digest('hex'), license.sha256);
    assert.ok(notices.includes(text), `${name}: complete license text`);
  }
}
assert.deepEqual((await readdir('Resources/Web')).sort(), ['renderer.js', 'shell.html', 'styles.css']);
assert.ok(original.get('Resources/Notices/THIRD_PARTY_NOTICES.md').equals(original.get('THIRD_PARTY_NOTICES.md')));
const shell = await readFile('Resources/Web/shell.html', 'utf8');
const css = await readFile('Resources/Web/styles.css', 'utf8');
const renderer = await readFile('web/renderer.js', 'utf8');
const blockEntries = renderer.match(/^function blockEntries\(container\) \{[\s\S]*?^\}/m)?.[0];
assert.ok(blockEntries, 'source-named block identity helper exists');
assert.doesNotMatch(blockEntries, /setAttribute|dataset/, 'block keys stay private, not in HTML attributes');
assert.ok(!/(?:src|href)=["']https?:/i.test(shell));
assert.ok(!/@import|url\(/i.test(css));
assert.match(css, /@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{\s*\.changed-flash\s*\{\s*animation:\s*none;/,
  'reduced motion disables the changed-block animation');
for (let run = 1; run <= 2; run++) {
  const build = spawnSync(process.execPath, ['scripts/build-renderer.mjs'], { encoding: 'utf8', timeout: 30000 });
  assert.equal(build.error, undefined);
  assert.equal(build.status, 0, build.stderr);
  for (const path of paths) assert.ok(original.get(path).equals(await readFile(path)), `reproducible pass ${run}: ${path}`);
}
console.log(`PASS ${manifest.assets.length} asset SHA-256 records, ${production.length} locked production-package/license records, offline shell/CSS and 2 byte-identical regenerations`);
