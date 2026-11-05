const test = require('node:test');
const assert = require('node:assert/strict');
const { skim, sections, briefing, securityNotice } = require('../ui/format.js');

test('all seven highlight kinds render without leaking tags', () => {
  for (const kind of 'uadpmnl') {
    assert.equal(skim(`<<${kind}|example>>`), `<span class="${kind === 'p' ? 'pn' : kind}">example</span>`);
  }
});
test('untrusted headings and highlighted HTML remain escaped', () => {
  const html = briefing('## <img src=x onerror=alert(1)>\n<<a|<script>alert(1)</script>>>');
  assert.ok(!html.includes('<img') && !html.includes('<script>'));
  assert.ok(html.includes('&lt;img') && html.includes('&lt;script&gt;'));
});
test('empty, dotted, and unfinished highlights do not leak model markup', () => {
  assert.equal(skim('Done. <<u|...>> <<d|…>> <<a|reply soon'), 'Done.   reply soon');
});
test('headings separate sections and empty sections disappear', () => {
  assert.deepEqual(sections('## Needs you\nReply to Oscar.\n\n## Today\n\n## News\nSolar grew.'), [
    { heading: 'Needs you', body: 'Reply to Oscar.' }, { heading: 'News', body: 'Solar grew.' }
  ]);
  assert.equal(briefing('Old briefing.'), '<p>Old briefing.</p>');
});
test('section bodies keep paragraph breaks and highlights', () => {
  assert.equal(briefing('## Needs you\n<<a|Reply>> today.\n\nPay rent.'),
    '<h3 class="brief-heading">Needs you</h3><p><span class="a">Reply</span> today.</p><p>Pay rent.</p>');
});
test('only account security notices get a prominent That was me action', () => {
  const message = (subject, snippet = '') => ({ from_address: 'notifications@example.com', subject, snippet });
  assert.equal(securityNotice(message('Security alert', 'New sign-in on Mac')), true);
  assert.equal(securityNotice(message('A personal access token was added')), true);
  assert.equal(securityNotice(message('Newly granted account access')), true);
  assert.equal(securityNotice(message('[everyday] Run failed: Windows - main')), false);
  assert.equal(securityNotice(message('Thursday roadmap sync')), false);
});
