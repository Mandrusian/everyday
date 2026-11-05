// Test harness only: stands in for the Rust side so the UI's own logic can be exercised in any browser.
const rows = [
  { thread_id: "t1", from: "Oscar Fox", from_address: "oscar@acme.com.au", subject: "Thursday roadmap sync", snippet: "Does 3pm still work?", attention: true, priority: 90, category: "NeedsReply", count: 1 },
  { thread_id: "t2", from: "Google", from_address: "no-reply@accounts.google.com", subject: "Security alert", snippet: "New sign-in", attention: true, priority: 80, category: "Important", count: 1 },
  { thread_id: "t3", from: "Morning Brew", from_address: "hi@brew.com", subject: "Weekday briefing", snippet: "", attention: false, priority: 20, category: "Newsletter", count: 1 }];
let handled = new Set(), taskStore = [], prefs = { onboarded: "1" };
window.__calls = []; window.__brief = 0;
window.__TAURI__ = { core: { invoke: async (cmd, a = {}) => { window.__calls.push([cmd, a]);
  switch (cmd) {
    case "app_state": return { email: "me@example.com", has_ai_key: true };
    case "inbox": return rows.filter(r => !handled.has(r.thread_id));
    case "mark_handled": a.threadIds.forEach(t => handled.add(t)); if (a.threadIds.includes("t2")) handled.add("t2"); return a.threadIds.length;
    case "make_briefing": return "## Needs you\n<<a|Reply to Oscar>> about the <<u|roadmap sync>> by <<d|Thursday>>." + (handled.has("t2") ? "" : " Google also sent a security alert.") + "\n\n## Today\n<<n|31°C>> in <<l|Cairns>>. Rent is <<m|$240>>.\n\n## News\nSolar had a record year.";
    case "quick_replies": return [{ label: "Add as task", kind: "task", thread_ids: ["t1"], text: "" }].concat(handled.has("t2") ? [] : [{ label: "That was me", kind: "handled", thread_ids: ["t2"], text: "" }]);
    case "upcoming": return [{ title: "Standup", when: "Thu 5 Nov, 09:30", location: "" }];
    case "task_list": return taskStore; case "add_task": taskStore.push({ id: "k" + taskStore.length, title: a.input, due: null, priority: "medium", repeats: null }); return {};
    case "toggle_task": case "delete_task": taskStore = taskStore.filter(t => t.id !== a.id); return null;
    case "thread": return [{ id: "m1", from_name: "Oscar", from_address: "oscar@acme.com.au", subject: "Thursday roadmap sync", body: "Does 3pm still work?", attachment_names: ["Agenda.pdf"] }];
    case "stories": return [{ title: "Solar record", source: "ABC", url: "https://x.test", summary: "s", also: 1 }]; case "news_refresh": return 5;
    case "swipe_deck": return [{ title: "Reef bounces back", source: "Nature", url: "https://x.test/r", summary: "Good news", also: 0 }]; case "react": return null;
    case "ask": return { text: "Oscar needs a reply.", sources: [{ tag: "M1", title: "Oscar: Roadmap", kind: "mail", reference: "t1" }] };
    case "get_pref": return prefs[a.key] || ""; case "set_pref": prefs[a.key] = a.value; return null;
    case "morning_due": return false; case "speech_chunks": return [a.text]; case "briefing_preview": return a.text.slice(0, 50);
    case "snooze": case "toggle_vip": return true; default: return null; } } } };
