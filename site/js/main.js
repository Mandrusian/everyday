import { config } from './config.js';

const root = document.documentElement;
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

// ---- Links that need real URLs (see config.js) ----
document.querySelectorAll('[data-download]').forEach(a => { if (config.downloadUrl) a.href = config.downloadUrl; });
document.querySelectorAll('[data-repo]').forEach(a => { if (config.repoUrl) { a.href = config.repoUrl; a.target = '_blank'; a.rel = 'noopener'; } });
if (config.repoUrl) document.querySelectorAll('[data-repo-url]').forEach(s => s.textContent = config.repoUrl.replace('https://', ''));

// ---- Light / dark ----
// The head script already applied a saved choice; this keeps the switch, its label and the browser bar in step.
const darkQuery = matchMedia('(prefers-color-scheme: dark)');
const themeBtn = document.querySelector('.theme');
const themeMeta = document.querySelector('meta[name="theme-color"]');
function syncTheme() {
  const mode = root.dataset.theme || (darkQuery.matches ? 'dark' : 'light');
  root.dataset.mode = mode;
  themeBtn?.setAttribute('aria-label', mode === 'dark' ? 'Switch to light mode' : 'Switch to dark mode');
  themeMeta?.setAttribute('content', mode === 'dark' ? '#0b0a09' : '#f1ebdd');
}
themeBtn?.addEventListener('click', () => {
  const next = root.dataset.mode === 'dark' ? 'light' : 'dark';
  // Picking the system's own mode clears the override, so the page follows the system again.
  const system = darkQuery.matches ? 'dark' : 'light';
  if (next === system) delete root.dataset.theme; else root.dataset.theme = next;
  try { next === system ? localStorage.removeItem('theme') : localStorage.setItem('theme', next); } catch (e) {}
  syncTheme();
});
darkQuery.addEventListener?.('change', syncTheme);
syncTheme();

// ---- Torn paper ----
// A seeded random walk, so each edge always tears the same way.
function rng(seed) {
  let a = seed * 9301 + 49297;
  return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}
function edge(seed, steps = 90) {
  const r = rng(seed), pts = [];
  let y = 0.5, drift = 0;
  for (let i = 0; i <= steps; i++) {
    drift = drift * 0.75 + (r() - 0.5) * 0.35;        // slow wander of the tear
    y = Math.min(1, Math.max(0, y + drift * 0.5));
    const fibre = (r() - 0.5) * 0.22;                  // fine jagged fibres
    pts.push([i / steps * 100, Math.min(1, Math.max(0, y + fibre))]);
  }
  return pts;
}
// Polygon whose top follows the edge; depth is how far (px) the tear dips, lift moves it up.
function poly(pts, depth, lift = 0, rough = 0, seed = 1) {
  const r = rng(seed + 99);
  const top = pts.map(([x, y]) => `${x.toFixed(2)}% ${(y * depth - lift + (rough ? (r() - 0.5) * rough : 0)).toFixed(1)}px`);
  return `polygon(${top.join(',')},100% 100%,0% 100%)`;
}
// Each section's sheet tears over the one above it: a faint shadow, pale fibres, then the sheet.
function tearSheets() {
  const depth = parseFloat(getComputedStyle(root).getPropertyValue('--tear')) || 28;
  document.querySelectorAll('[data-tear]').forEach(sheet => {
    const seed = +sheet.dataset.tear, bg = sheet.querySelector(':scope > .bg');
    if (!bg) return;
    let shade = sheet.querySelector(':scope > .tear-shade'), fibre = sheet.querySelector(':scope > .tear-fibre');
    if (!shade) {
      shade = Object.assign(document.createElement('div'), { className: 'tear-shade' });
      fibre = Object.assign(document.createElement('div'), { className: 'tear-fibre' });
      shade.setAttribute('aria-hidden', 'true'); fibre.setAttribute('aria-hidden', 'true');
      sheet.insertBefore(shade, bg); sheet.insertBefore(fibre, bg);
    }
    const pts = edge(seed), d = depth * 0.8;
    shade.style.clipPath = poly(pts, d, 5, 0);
    fibre.style.clipPath = poly(pts, d, 3, 3.5, seed);
    bg.style.clipPath = poly(pts, d, -2, 0);
  });
}
tearSheets();
let lastTear = getComputedStyle(root).getPropertyValue('--tear');
addEventListener('resize', () => { const t = getComputedStyle(root).getPropertyValue('--tear'); if (t !== lastTear) { lastTear = t; tearSheets(); } });

// A slip of paper torn along its top and bottom, straight along its sides.
function slipPoly(seed, depth = 7) {
  const top = edge(seed, 40), bottom = edge(seed + 50, 40).reverse();
  const t = top.map(([x, y]) => `${x.toFixed(2)}% ${(y * depth).toFixed(1)}px`);
  const b = bottom.map(([x, y]) => `${x.toFixed(2)}% calc(100% - ${(y * depth).toFixed(1)}px)`);
  return `polygon(${t.join(',')},${b.join(',')})`;
}
document.querySelectorAll('.slip').forEach((s, i) => { s.style.clipPath = slipPoly(i * 13 + 5); });

// A scrap torn on all four sides, for under the app windows.
function scrapPoly(seed) {
  const r = rng(seed * 7 + 3), pts = [], n = 22;
  const side = (from, to, axis) => {
    for (let i = 0; i < n; i++) {
      const t = i / n, j = (r() - 0.5) * 2.4;
      const x = from[0] + (to[0] - from[0]) * t, y = from[1] + (to[1] - from[1]) * t;
      pts.push(axis === 'h' ? [x, y + j] : [x + j * 0.7, y]);
    }
  };
  side([1.5, 1.5], [98.5, 1.5], 'h'); side([98.5, 1.5], [98.5, 98.5], 'v');
  side([98.5, 98.5], [1.5, 98.5], 'h'); side([1.5, 98.5], [1.5, 1.5], 'v');
  return `polygon(${pts.map(([x, y]) => `${x.toFixed(2)}% ${y.toFixed(2)}%`).join(',')})`;
}
document.querySelectorAll('.win.reveal').forEach((win, i) => {
  const stack = document.createElement('div');
  stack.className = 'stack reveal';
  win.classList.remove('reveal');
  win.before(stack);
  const scrap = document.createElement('div');
  scrap.className = 'scrap' + (i % 2 ? ' alt' : '');
  scrap.setAttribute('aria-hidden', 'true');
  scrap.style.clipPath = scrapPoly(i + 1);
  stack.append(scrap, win);
});

// ---- Hero: the copy rises line by line while the slips fall into order ----
document.querySelectorAll('.hero .hl').forEach((el, i) => el.style.setProperty('--i', i));
requestAnimationFrame(() => requestAnimationFrame(() => root.classList.add('loaded')));

// ---- Page chrome: nav background, progress bar, reveals ----
const nav = document.getElementById('nav');
const bar = document.querySelector('.progress i');
function onScroll() {
  nav.classList.toggle('solid', scrollY > 40);
  const max = document.documentElement.scrollHeight - innerHeight;
  bar.style.transform = `scaleX(${max > 0 ? scrollY / max : 0})`;
}
addEventListener('scroll', onScroll, { passive: true }); onScroll();
const io = new IntersectionObserver(es => es.forEach(e => {
  if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
}), { threshold: 0.22, rootMargin: '0px 0px -8% 0px' });
document.querySelectorAll('.reveal').forEach(el => io.observe(el));

// ---- Pointer: slips and tickets lean slightly toward it ----
if (!reduce && matchMedia('(hover: hover)').matches) {
  const slips = document.querySelector('.slips');
  if (slips) {
    let tx = 0, ty = 0, x = 0, y = 0, raf = 0;
    const step = () => {
      x += (tx - x) * 0.08; y += (ty - y) * 0.08;
      slips.style.setProperty('--px', x.toFixed(3)); slips.style.setProperty('--py', y.toFixed(3));
      raf = Math.abs(tx - x) + Math.abs(ty - y) > 0.001 ? requestAnimationFrame(step) : 0;
    };
    addEventListener('pointermove', e => {
      if (scrollY > innerHeight) return;
      tx = e.clientX / innerWidth - 0.5; ty = e.clientY / innerHeight - 0.5;
      if (!raf) raf = requestAnimationFrame(step);
    }, { passive: true });
  }
  document.querySelectorAll('.ticket').forEach(card => {
    card.addEventListener('pointermove', e => {
      const r = card.getBoundingClientRect();
      const x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
      card.style.transition = 'transform .15s ease-out';
      card.style.transform = `perspective(900px) rotateX(${(-y * 4).toFixed(2)}deg) rotateY(${(x * 5).toFixed(2)}deg) translateY(-3px)`;
    });
    card.addEventListener('pointerleave', () => { card.style.transition = ''; card.style.transform = ''; });
  });
}
