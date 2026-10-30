import MarkdownIt from 'markdown-it';
import DOMPurify from 'dompurify';
import hljs from 'highlight.js/lib/core';
import javascript from 'highlight.js/lib/languages/javascript';
import typescript from 'highlight.js/lib/languages/typescript';
import json from 'highlight.js/lib/languages/json';
import css from 'highlight.js/lib/languages/css';
import xml from 'highlight.js/lib/languages/xml';
import bash from 'highlight.js/lib/languages/bash';
import python from 'highlight.js/lib/languages/python';
import swift from 'highlight.js/lib/languages/swift';
import { tasklist } from '@mdit/plugin-tasklist';

for (const [name, grammar] of Object.entries({ javascript, typescript, json, css, xml, bash, python, swift })) {
  hljs.registerLanguage(name, grammar);
}
const md = new MarkdownIt({
  html: false, linkify: false, typographer: false,
  highlight(code, language) {
    if (language && hljs.getLanguage(language)) {
      return hljs.highlight(code, { language, ignoreIllegals: true }).value;
    }
    return ''; // markdown-it escapes plain code, including unknown/Mermaid languages.
  }
}).use(tasklist, { disabled: true, label: false });

function slug(text) {
  return text.normalize('NFC').toLowerCase().trim().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s+/gu, '-') || 'section';
}
function tokens(source) {
  const parsed = md.parse(source, {});
  const used = new Set();
  for (let i = 0; i < parsed.length; i++) {
    if (parsed[i].type !== 'heading_open') continue;
    const text = (parsed[i + 1]?.children ?? []).map(t => t.type === 'image' ? t.content : t.type === 'text' || t.type === 'code_inline' ? t.content : '').join('');
    const base = slug(text);
    let id = base, suffix = 2;
    while (used.has(id)) id = `${base}-${suffix++}`;
    used.add(id);
    parsed[i].attrSet('id', `heading-${id}`);
  }
  return parsed;
}
function walk(parsed, visit) {
  for (const token of parsed) {
    visit(token);
    // markdown-it renders image alt children as text, never as nested DOM elements.
    if (token.type !== 'image' && token.children) walk(token.children, visit);
  }
}
// Discovery uses the actual parser, not a regex: handles references, titles and escaped paths.
window.prepareMarkdown = source => {
  const images = new Set(), links = new Set();
  walk(tokens(source), token => {
    if (token.type === 'image') images.add(token.attrGet('src'));
    if (token.type === 'link_open') links.add(token.attrGet('href'));
  });
  return { images: [...images], links: [...links] };
};
let currentGeneration = 0;
let pendingDOM = null;
window.setRenderGeneration = generation => {
  if (generation > currentGeneration) { currentGeneration = generation; pendingDOM = null; }
  return currentGeneration;
};
window.stageMarkdown = (source, images, links, generation) => {
  if (generation !== currentGeneration) return false;
  const parsed = tokens(source);
  walk(parsed, token => {
    if (token.type === 'image') {
      const reference = token.attrGet('src');
      if (Object.hasOwn(images, reference)) token.attrSet('src', images[reference]);
      else {
        token.type = 'text'; token.tag = ''; token.nesting = 0; token.children = null;
        token.content = `Blocked or missing image: ${token.content}`;
        token.attrs = null;
        token.meta = { blockedImage: true };
      }
    }
    if (token.type === 'link_open') {
      const reference = token.attrGet('href');
      token.attrs = token.attrs.filter(([name]) => name !== 'href');
      if (Object.hasOwn(links, reference)) token.attrSet('href', links[reference]);
      else token.attrSet('class', 'blocked-link');
    }
  });
  const defaultText = md.renderer.rules.text;
  md.renderer.rules.text = (ts, i, options, env, self) => ts[i].meta?.blockedImage
    ? `<span class="blocked-image">${md.utils.escapeHtml(ts[i].content)}</span>`
    : defaultText(ts, i, options, env, self);
  let clean;
  try {
    clean = DOMPurify.sanitize(md.renderer.render(parsed, md.options, {}), {
      USE_PROFILES: { html: true }, SANITIZE_NAMED_PROPS: true,
      // Opaque gateway URLs are installed only by trusted code after sanitization below.
    });
  } finally { md.renderer.rules.text = defaultText; }
  const staging = document.createElement('template');
  staging.innerHTML = clean;
  // DOMPurify does not allow custom schemes by default. Restore ONLY exact native capabilities.
  const imageURLs = new Set(Object.values(images));
  const linkURLs = new Set(Object.values(links));
  const imageTokens = [], linkTokens = [];
  walk(parsed, t => {
    if (t.type === 'image') imageTokens.push(t.attrGet('src'));
    if (t.type === 'link_open') linkTokens.push(t.attrGet('href'));
  });
  const imageNodes = [...staging.content.querySelectorAll('img')];
  const linkNodes = [...staging.content.querySelectorAll('a')];
  const aligned = imageNodes.length === imageTokens.length && linkNodes.length === linkTokens.length;
  imageNodes.forEach((node, i) => {
    node.removeAttribute('srcset');
    const url = imageTokens[i];
    if (aligned && imageURLs.has(url) && url.startsWith('mdviewer://asset/')) node.setAttribute('src', url);
    else node.removeAttribute('src');
  });
  linkNodes.forEach((node, i) => {
    node.removeAttribute('href');
    const url = linkTokens[i];
    if (aligned && linkURLs.has(url) && url.startsWith('mdviewer://link/')) node.setAttribute('href', url);
  });
  for (const checkbox of staging.content.querySelectorAll('input')) {
    checkbox.disabled = true;
    checkbox.setAttribute('aria-label', checkbox.closest('li')?.textContent.trim() || 'Task');
  }
  if (!source.trim()) {
    const empty = document.createElement('p'); empty.className = 'empty-document';
    empty.textContent = 'Empty document'; staging.content.append(empty);
  }
  if (generation !== currentGeneration) return false;
  pendingDOM = { generation, content: staging.content };
  return true;
};
window.commitMarkdown = generation => {
  if (generation !== currentGeneration || pendingDOM?.generation !== generation) return false;
  const position = { x: scrollX, y: scrollY };
  document.getElementById('document').replaceChildren(pendingDOM.content);
  document.getElementById('document').dataset.generation = String(generation);
  pendingDOM = null;
  scrollTo(position.x, Math.min(position.y, Math.max(0, document.documentElement.scrollHeight - innerHeight)));
  return true;
};
// Kept as a trusted API for isolated renderer fixtures; production stages and commits separately.
window.renderMarkdown = (source, images, links, generation = currentGeneration) =>
  window.stageMarkdown(source, images, links, generation) && window.commitMarkdown(generation);
window.scrollToFragment = fragment => {
  const id = `user-content-heading-${fragment}`;
  const heading = document.getElementById(id) || document.getElementById(`user-content-heading-${slug(fragment)}`);
  if (heading) { heading.scrollIntoView(); heading.setAttribute('tabindex', '-1'); heading.focus({ preventScroll: true }); }
  return !!heading;
};
// Synthetic clicks must not request native routing, even if a future regression inserts scripts.
document.addEventListener('click', event => {
  if (event.target.closest('a') && !event.isTrusted) event.preventDefault();
});
