const test = require('node:test');
const assert = require('node:assert/strict');
const Replies = require('../ui/replies.js');

function fixture(send) {
  let tick, cancelled = false;
  const errors = [];
  const replies = new Replies({ send, failed: e => errors.push(e), setTimer: callback => { tick = callback; return 1; }, clearTimer: () => { cancelled = true; } });
  return { replies, errors, tick: () => tick(), cancelled: () => cancelled };
}
test('undo restores the correct thread draft and sends nothing', async () => {
  let sends = 0; const f = fixture(async () => { sends++; });
  f.replies.setDraft('a', 'Reply A'); const undo = f.replies.queue('a');
  f.replies.setDraft('b', 'Reply B');
  assert.equal(undo(), true); await f.tick();
  assert.equal(f.replies.draft('a'), 'Reply A'); assert.equal(f.replies.draft('b'), 'Reply B');
  assert.equal(sends, 0); assert.equal(f.cancelled(), true);
});
test('failed send restores the original without overwriting a newer draft', async () => {
  const f = fixture(async () => { throw new Error('offline'); });
  f.replies.setDraft('a', 'Original'); f.replies.queue('a'); f.replies.setDraft('a', 'New thought');
  await f.tick();
  assert.equal(f.replies.draft('a'), 'Original\n\nNew thought');
  assert.equal(f.replies.isPending('a'), false); assert.equal(f.errors[0].message, 'offline');
});
test('a pending reply cannot be queued twice and success keeps subsequent typing', async () => {
  const sends = []; const f = fixture(async (id, body) => sends.push([id, body]));
  f.replies.setDraft('a', 'First'); f.replies.queue('a'); f.replies.setDraft('a', 'Second');
  assert.equal(f.replies.queue('a'), null); await f.tick();
  assert.deepEqual(sends, [['a', 'First']]); assert.equal(f.replies.draft('a'), 'Second');
});
test('undo cannot claim cancellation once sending has started', async () => {
  let resolve; const f = fixture(() => new Promise(r => { resolve = r; }));
  f.replies.setDraft('a', 'First'); const undo = f.replies.queue('a'); const sending = f.tick();
  assert.equal(undo(), false); resolve(); await sending;
  assert.equal(f.replies.isPending('a'), false);
});
