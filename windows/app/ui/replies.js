// Reply drafts survive navigation and failed sends. Timers are injectable for deterministic tests.
(function (root) {
  class Replies {
    constructor({ send, changed = () => {}, failed = () => {}, sent = () => {}, setTimer = (callback, delay) => root.setTimeout(callback, delay), clearTimer = timer => root.clearTimeout(timer) }) {
      Object.assign(this, { send, changed, failed, sent, setTimer, clearTimer });
      this.drafts = new Map(); this.pending = new Map();
    }
    draft(id) { return this.drafts.get(id) || ""; }
    setDraft(id, text) { if (text) this.drafts.set(id, text); else this.drafts.delete(id); }
    isPending(id) { return this.pending.has(id); }
    restore(id, body) {
      const newer = this.draft(id);
      this.setDraft(id, newer ? `${body}\n\n${newer}` : body);
    }
    queue(id, delay = 10000) {
      const body = this.draft(id).trim();
      if (!body || this.pending.has(id)) return null;
      const item = { body, sending: false };
      this.drafts.delete(id); this.pending.set(id, item);
      item.timer = this.setTimer(() => this.deliver(id, item), delay);
      this.changed(id);
      return () => {
        if (this.pending.get(id) !== item || item.sending) return false;
        this.clearTimer(item.timer); this.pending.delete(id); this.restore(id, body); this.changed(id);
        return true;
      };
    }
    async deliver(id, item) {
      if (this.pending.get(id) !== item) return;
      item.sending = true;
      try { await this.send(id, item.body); }
      catch (error) {
        this.pending.delete(id); this.restore(id, item.body); this.changed(id); this.failed(error); return;
      }
      this.pending.delete(id); this.changed(id); this.sent(id);
    }
  }
  if (typeof module !== "undefined" && module.exports) module.exports = Replies;
  else root.EverydayReplies = Replies;
})(globalThis);
