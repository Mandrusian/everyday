// Light/dark switch for the document pages. The head script has already applied a saved choice.
(function () {
  var d = document.documentElement, q = matchMedia('(prefers-color-scheme: dark)'), b = document.querySelector('.theme');
  if (!b) return;
  function sync() { d.dataset.mode = d.dataset.theme || (q.matches ? 'dark' : 'light'); b.setAttribute('aria-label', d.dataset.mode === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'); }
  b.addEventListener('click', function () {
    var next = d.dataset.mode === 'dark' ? 'light' : 'dark', sys = q.matches ? 'dark' : 'light';
    if (next === sys) delete d.dataset.theme; else d.dataset.theme = next;
    try { next === sys ? localStorage.removeItem('theme') : localStorage.setItem('theme', next); } catch (e) {}
    sync();
  });
  q.addEventListener && q.addEventListener('change', sync); sync();
})();
