const { invoke } = window.__TAURI__.core;
const $ = (s, r = document) => r.querySelector(s), main = $("#main");
const { esc, skim, briefing: renderBriefing, securityNotice } = window.EverydayFormat;
let view = "today", selected = null, state = { email: null, has_ai_key: false }, brief = "", replies = [], used = new Set(), busy = {};

function say(text, undo, secs = 4) {
  const b = $("#banner"); $("#bt").textContent = text; const u = $("#bu"); u.style.display = undo ? "" : "none"; u.onclick = () => { b.style.display = "none"; undo && undo(); };
  b.style.display = "flex"; clearTimeout(say.t); say.t = setTimeout(() => b.style.display = "none", secs * 1000);
}
const fail = e => say(String(e), null, 7);
const replyStore = new window.EverydayReplies({
  send: (threadId, body) => invoke("send_reply", { threadId, body }),
  changed: updateReplyComposer, failed: fail, sent: () => say("Reply sent.")
});
function updateReplyComposer(id) {
  if (view !== "inbox" || selected !== id || !$("#rb")) return;
  $("#rb").value = replyStore.draft(id);
  $("#sd").disabled = replyStore.isPending(id);
}

async function refreshState() { state = await invoke("app_state"); $("#status").textContent = state.email ? `${state.email} · click to sync` : "Connect mail in Settings"; }
$("#status").onclick = async () => { if (!state.email) return show("settings"); say("Syncing…"); try { say(await invoke("sync_mail")); } catch (e) { fail(e); } show(view); };
$("#nav").onclick = e => { const v = e.target.dataset.v; if (v) show(v); };
function show(v) { view = v; document.querySelectorAll("#nav a").forEach(a => a.classList.toggle("on", a.dataset.v === v)); ({ today, inbox, news, tasks, assistant, settings })[v](); }

async function handle(threadIds) {   // "That was me": covers the whole automated sender group, then rewrites the briefing without it
  const n = await invoke("mark_handled", { threadIds });
  say(n > 1 ? `Marked ${n} conversations as handled.` : "Marked as handled."); brief = ""; replies = []; used = new Set(); show(view);
  if (state.has_ai_key) writeBriefing();
}
async function writeBriefing() {
  try { brief = await invoke("make_briefing"); replies = await invoke("quick_replies", { briefingText: brief }); } catch (e) { brief = ""; fail(e); }
  if (view === "today") today();
}
async function perform(r, i) {
  used.add(i);
  if (r.kind === "handled") return handle(r.thread_ids);
  if (r.kind === "task") { for (const t of r.thread_ids.slice(0, 3)) { const th = await invoke("thread", { threadId: t }); await invoke("add_task", { input: "Follow up: " + (th.at(-1)?.subject || "email") }); } say("Task added."); }
  else if (r.kind === "remind") { for (const t of r.thread_ids.slice(0, 3)) await invoke("snooze", { threadId: t, hours: 4 }); say("I'll bring it back this evening."); }
  else if (r.kind === "ignore") say("Use the Inbox menu to always treat mail like this as handled.");
  else if (r.kind === "ask") say(r.text || "Ask in the Inbox thread.");
  show(view);
}

async function today() {
  const rows = (await invoke("inbox")).filter(r => r.attention);
  main.innerHTML = `<h1>Good day.</h1><p class="sub">${rows.length ? (rows.length === 1 ? "1 thing needs" : rows.length + " things need") + " you today." : "Nothing urgent right now."} Nothing is sent or deleted without your approval.</p>
  <div class="card" style="padding:18px"><b class="muted" style="font-size:12px;letter-spacing:.1em">DAILY BRIEFING</b>
  ${brief ? `<div class="brief">${renderBriefing(brief)}</div><p><button id="ls">Listen</button></p>` : `<p class="muted">${state.has_ai_key ? "" : "Add a Gemini key in Settings to write briefings. "}<button class="p" id="wb">Write briefing</button></p>`}
  <div class="chips">${replies.map((r, i) => used.has(i) ? "" : `<button data-i="${i}">${esc(r.label)}</button>`).join("")}</div></div>
  <div id="up"></div><div class="card">${rows.map(r => `<div class="row"><div class="t"><b>${esc(r.from)}</b>: ${esc(r.subject)}<small>${esc(r.snippet)}</small></div>
    <div class="row-actions">${securityNotice(r) ? `<button data-h="${esc(r.thread_id)}">That was me</button>` : `<details class="more-actions"><summary aria-label="More actions for ${esc(r.subject)}">…</summary><button data-h="${esc(r.thread_id)}">Mark as handled</button></details>`} <button data-o="${r.thread_id}">Open</button></div></div>`).join("") || '<p class="muted">Nothing needs you.</p>'}</div>`;
  invoke("upcoming").then(ev => { if (ev.length) $("#up").innerHTML = `<div class="card" style="padding:12px 18px"><b class="muted" style="font-size:12px;letter-spacing:.1em">UP NEXT</b>${ev.map(e => `<div class="row"><div class="t">${esc(e.title)}<small>${esc(e.when)}${e.location ? " · " + esc(e.location) : ""}</small></div></div>`).join("")}</div>`; }).catch(() => {});
  const ls = $("#ls"); if (ls) ls.onclick = () => listen(brief);
  const wb = $("#wb"); if (wb) wb.onclick = async () => { wb.disabled = true; wb.textContent = "Writing…"; await writeBriefing(); };
  main.querySelectorAll("[data-i]").forEach(b => b.onclick = () => perform(replies[+b.dataset.i], +b.dataset.i));
  main.querySelectorAll("[data-h]").forEach(b => b.onclick = () => handle([b.dataset.h]));
  main.querySelectorAll("[data-o]").forEach(b => b.onclick = () => { selected = b.dataset.o; show("inbox"); });
}

let player = null;
async function listen(text) {   // natural voice through Gemini when a key exists (cached), otherwise the voices installed on this PC
  if (player) { player.pause(); player = null; window.speechSynthesis?.cancel(); return; }
  const parts = await invoke("speech_chunks", { text });
  try {
    if (!state.has_ai_key) throw new Error("no key");
    for (const p of parts) { const wav = await invoke("speak", { text: p, voice: await invoke("get_pref", { key: "voice" }) || "Charon" });
      await new Promise(res => { player = new Audio("data:audio/wav;base64," + wav); player.onended = res; player.onerror = res; player.play(); }); if (!player) break; }
  } catch (_) {
    for (const p of parts) await new Promise(res => { const u = new SpeechSynthesisUtterance(p); u.onend = res; u.onerror = res; window.speechSynthesis.speak(u); });
  }
  player = null;
}

async function inbox() {
  const rows = await invoke("inbox");
  main.innerHTML = `<div class="split"><div class="card list" style="padding:0 14px">${rows.map(r => `<div class="row ${r.thread_id === selected ? "sel" : ""}" data-t="${r.thread_id}" style="cursor:pointer"><div class="t"><b>${esc(r.from)}</b> ${r.attention ? '<span class="chip">Needs you</span>' : ""}<small>${esc(r.subject)}</small></div></div>`).join("") || '<p class="muted">No mail yet. Connect in Settings, then click the status line to sync.</p>'}</div><div id="thread"></div></div>`;
  main.querySelectorAll("[data-t]").forEach(el => el.onclick = () => { selected = el.dataset.t; inbox(); });
  if (selected) await thread(selected);
}
async function thread(id) {
  const msgs = await invoke("thread", { threadId: id }); const last = msgs.at(-1); if (!last) return;
  $("#thread").innerHTML = `<h2 style="font:400 26px var(--serif);margin:0 0 10px">${esc(last.subject)}</h2>
  <div class="row-actions" style="margin-bottom:12px">${securityNotice(last) ? '<button id="th">That was me</button>' : '<details class="more-actions"><summary aria-label="More conversation actions">…</summary><button id="th">Mark as handled</button></details>'} <button id="sn">Snooze until tomorrow</button> <button id="vp">VIP</button> <button id="ar">Archive</button> <button id="tr">Trash</button></div>
  ${msgs.map(m => `<div class="card" style="padding:12px 18px"><b>${esc(m.from_name)}</b> <span class="muted">${esc(m.from_address)}</span><p style="white-space:pre-wrap">${esc(m.body.slice(0, 4000))}</p>${m.attachment_names?.length ? `<p class="muted">Attachments: ${m.attachment_names.map(esc).join(", ")}</p>` : ""}</div>`).join("")}
  <textarea id="rb" rows="5" placeholder="Write a reply. Nothing is sent until you press Send, and you then have 10 seconds to undo.">${esc(replyStore.draft(id))}</textarea><button class="p" id="sd" ${replyStore.isPending(id) ? "disabled" : ""}>Review and send</button>`;
  $("#rb").oninput = event => replyStore.setDraft(id, event.target.value);
  $("#th").onclick = () => handle([id]);
  $("#sn").onclick = async () => { await invoke("snooze", { threadId: id, hours: 18 }); say("Snoozed until tomorrow."); selected = null; inbox(); };
  $("#vp").onclick = async () => say((await invoke("toggle_vip", { address: last.from_address })) ? "VIP: their mail rises to the top." : "No longer a VIP.");
  $("#ar").onclick = async () => { try { await invoke("archive", { threadId: id }); say("Archived."); selected = null; inbox(); } catch (e) { fail(e); } };
  $("#tr").onclick = async () => { if (!confirm("Move this conversation to Trash?")) return; try { await invoke("trash", { threadId: id }); say("Moved to Trash."); selected = null; inbox(); } catch (e) { fail(e); } };
  $("#sd").onclick = () => {
    replyStore.setDraft(id, $("#rb").value);
    const undo = replyStore.queue(id); if (!undo) return;
    say("Sending your reply in 10 seconds.", () => { if (undo()) say("Not sent. Your draft is back."); }, 10);
  };
}

async function news() {
  main.innerHTML = '<h1>News</h1><p class="sub"><button id="rf">Refresh</button> <button id="tr2">Train my feed</button></p><div id="ns"></div>';
  $("#tr2").onclick = deck;
  const draw = async () => { const s = await invoke("stories"); $("#ns").innerHTML = `<div class="card">${s.map(x => `<div class="row"><div class="t"><small>${esc(x.source)}${x.also ? ` · ${x.also} more sources` : ""}</small><a href="${esc(x.url)}" target="_blank" style="color:inherit"><b>${esc(x.title)}</b></a></div></div>`).join("") || '<p class="muted">Press Refresh.</p>'}</div>`; };
  $("#rf").onclick = async () => { say("Fetching feeds…"); try { say((await invoke("news_refresh")) + " articles."); } catch (e) { fail(e); } draw(); }; draw();
}

async function deck() {   // swipe-style: Interested, Not for me, Love it; your feed learns on this PC
  const cards = await invoke("swipe_deck"); let i = 0;
  const draw = () => { const c = cards[i]; if (!c) { main.innerHTML = '<h1>All caught up</h1><p class="sub">Your feed has learned from that.</p>'; setTimeout(news, 1200); return; }
    main.innerHTML = `<div class="deck"><div class="card"><small class="muted">${esc(c.source)} · ${i + 1} of ${cards.length}</small><h2>${esc(c.title)}</h2><p class="muted">${esc(c.summary)}</p>
    <button data-r="-1">Not for me</button> <button data-r="1" class="p">Interested</button> <button data-r="2">Love it</button> <button id="sk2">Skip</button></div></div>`;
    main.querySelectorAll("[data-r]").forEach(b => b.onclick = async () => { await invoke("react", { url: c.url, title: c.title, source: c.source, reaction: +b.dataset.r }); i++; draw(); }); $("#sk2").onclick = () => { i++; draw(); }; };
  draw();
}

let chat = [];
async function assistant() {
  main.innerHTML = `<h1>Ask everyday.</h1><p class="sub">I answer from your mail, tasks and news. I can't send or change anything.</p><div id="msgs"></div>
  <input id="q" placeholder="What needs my attention today?"><button class="p" id="go">Ask</button> <button id="cl">Clear</button>`;
  const draw = () => { $("#msgs").innerHTML = chat.map(m => `<div class="bubble ${m.role === "user" ? "me" : "ai"}">${esc(m.text)}${(m.sources || []).map((s, i) => `<div><button data-s="${esc(s.reference)}" data-k="${s.kind}">${i + 1}  ${esc(s.title.slice(0, 60))}</button></div>`).join("")}</div>`).join("");
    main.querySelectorAll("[data-s]").forEach(b => b.onclick = () => { if (b.dataset.k === "mail") { selected = b.dataset.s; show("inbox"); } else window.open(b.dataset.s, "_blank"); }); };
  const go = async () => { const q = $("#q").value.trim(); if (!q) return; $("#q").value = ""; const history = chat.map(m => [m.role, m.text]); chat.push({ role: "user", text: q }); draw();
    try { const r = await invoke("ask", { question: q, history }); chat.push({ role: "assistant", text: r.text, sources: r.sources }); } catch (e) { fail(e); } draw(); };
  $("#go").onclick = go; $("#q").onkeydown = e => { if (e.key === "Enter") go(); }; $("#cl").onclick = () => { chat = []; draw(); }; draw();
}

async function tasks() {
  const list = await invoke("task_list");
  main.innerHTML = `<h1>Tasks</h1><input id="qa" placeholder="Add a task, like “pay rent friday 5pm high”, and press Return"><div id="hint"></div>
  <div class="card">${list.map(t => `<div class="row"><div class="t"><label><input type="checkbox" data-c="${t.id}" style="width:auto;margin:0 8px 0 0"> ${esc(t.title)}${t.repeats ? " ↻" : ""}</label><small>${t.due ? new Date(t.due * 1000).toLocaleString() : ""} ${t.priority === "high" ? "· high priority" : ""}</small></div><button data-d="${t.id}">Delete</button></div>`).join("") || '<p class="muted">Nothing to do.</p>'}</div>`;
  const qa = $("#qa"); qa.focus();
  qa.oninput = () => { hint(qa.value); };
  qa.onkeydown = async e => { if (e.key === "Enter" && qa.value.trim()) { await invoke("add_task", { input: qa.value }); tasks(); } };
  main.querySelectorAll("[data-c]").forEach(c => c.onchange = async () => { await invoke("toggle_task", { id: c.dataset.c }); tasks(); });
  main.querySelectorAll("[data-d]").forEach(b => b.onclick = async () => { await invoke("delete_task", { id: b.dataset.d }); tasks(); });
}
async function hint(v) { $("#hint").textContent = v.trim().length > 2 ? "Enter adds: " + v : ""; }

async function settings() {
  const instr = await invoke("get_pref", { key: "briefingInstructions" }), muted = await invoke("get_pref", { key: "mutedTopics" });
  main.innerHTML = `<h1>Settings</h1><div class="card" style="padding:16px 18px"><b>Mail (IMAP with an app password)</b>
  <input id="em" placeholder="Email address" value="${esc(state.email || "")}"><input id="pw" type="password" placeholder="App password">
  <input id="ih" placeholder="IMAP host" value="imap.gmail.com"><input id="sh" placeholder="SMTP host" value="smtp.gmail.com"><button class="p" id="cm">Connect</button></div>
  <div class="card" style="padding:16px 18px"><b>AI (Gemini key, stored in Windows Credential Manager)</b><input id="ak" type="password" placeholder="${state.has_ai_key ? "A key is saved. Paste a new one to replace it." : "Paste your key"}"><button id="sk">Save and test</button></div>
  <div class="card" style="padding:16px 18px"><b>Your morning briefing</b><textarea id="bi" rows="3" placeholder="e.g. Skip anything about Hong Kong. Keep it under 100 words.">${esc(instr)}</textarea><input id="mt" placeholder="Hide these topics, comma separated" value="${esc(muted)}"><button id="sp">Save</button></div>
  <div class="card" style="padding:16px 18px"><b>Calendar (read-only)</b><p class="muted">Paste the secret iCal link from Google Calendar, Outlook or iCloud. Events show under Today and in the briefing.</p><input id="ics" placeholder="https://… .ics" value="${esc(await invoke("get_pref", { key: "icsUrl" }))}"><button id="si">Save</button></div>
  <div class="card" style="padding:16px 18px"><b>Voice and morning briefing</b><p class="muted">Natural voice (Gemini, uses your key) falls back to the voices on this PC.</p>
  <input id="vc" placeholder="Voice, e.g. Charon" value="${esc(await invoke("get_pref", { key: "voice" }))}"><label><input type="checkbox" id="mo" style="width:auto"> Write my briefing and notify me at <input id="mh" type="number" min="4" max="12" value="${esc((await invoke("get_pref", { key: "morningHour" })) || 7)}" style="width:70px;display:inline-block"> :00</label><br><button id="sv">Save</button></div>`;
  $("#si").onclick = async () => { await invoke("set_pref", { key: "icsUrl", value: $("#ics").value.trim() }); say("Saved."); };
  $("#mo").checked = (await invoke("get_pref", { key: "morningOn" })) === "1";
  $("#sv").onclick = async () => { await invoke("set_pref", { key: "voice", value: $("#vc").value }); await invoke("set_pref", { key: "morningOn", value: $("#mo").checked ? "1" : "0" }); await invoke("set_pref", { key: "morningHour", value: $("#mh").value }); say("Saved."); };
  $("#cm").onclick = async () => { try { say(await invoke("connect_mail", { email: $("#em").value.trim(), password: $("#pw").value, imapHost: $("#ih").value.trim(), imapPort: 993, smtpHost: $("#sh").value.trim(), smtpPort: 465 })); await refreshState(); } catch (e) { fail(e); } };
  $("#sk").onclick = async () => { try { if ($("#ak").value.trim()) await invoke("save_ai_key", { key: $("#ak").value }); say("The AI says: " + await invoke("ai_test")); await refreshState(); } catch (e) { fail(e); } };
  $("#sp").onclick = async () => { await invoke("set_pref", { key: "briefingInstructions", value: $("#bi").value }); await invoke("set_pref", { key: "mutedTopics", value: $("#mt").value }); say("Saved."); };
}

// First run: name, AI key, topics, then mail. Everything can be skipped and changed later in Settings.
async function wizard() {
  if (await invoke("get_pref", { key: "onboarded" }) === "1") return;
  const w = $("#wiz"), b = $("#wizb"); w.style.display = "grid"; const topics = ["technology", "ai", "world", "science", "business", "health", "sport", "arts"]; const picked = new Set(["technology", "ai", "world"]);
  const steps = [
    () => { b.innerHTML = `<div class="brand" style="font-size:44px">everyday<b>.</b></div><h1>Mail, news and tasks in one calm place.</h1><p class="muted">Your data stays on this PC. You bring the AI. Nothing is sent or deleted without your approval.</p><button class="p" id="nx">Get started</button>`; },
    () => { b.innerHTML = `<h1>Choose your AI</h1><p class="muted">A Gemini key from aistudio.google.com/apikey sorts mail and writes your briefing. Skipping is fine.</p><input id="k" type="password" placeholder="Gemini API key"><p id="r" class="muted"></p><button id="t">Save and test</button> <button class="p" id="nx">Next</button>`;
      $("#t").onclick = async () => { try { await invoke("save_ai_key", { key: $("#k").value }); $("#r").textContent = "The AI says: " + await invoke("ai_test"); } catch (e) { $("#r").textContent = String(e); } }; },
    () => { b.innerHTML = `<h1>What do you like to read?</h1><div class="chips">${topics.map(t => `<button data-t="${t}" class="${picked.has(t) ? "p" : ""}">${t}</button>`).join("")}</div><button class="p" id="nx">Next</button>`;
      b.querySelectorAll("[data-t]").forEach(x => x.onclick = () => { picked.has(x.dataset.t) ? picked.delete(x.dataset.t) : picked.add(x.dataset.t); x.classList.toggle("p"); }); },
    () => { b.innerHTML = `<h1>Connect your mail</h1><p class="muted">Use an app password. You can skip this and connect later in Settings.</p><input id="em" placeholder="Email address"><input id="pw" type="password" placeholder="App password"><input id="ih" placeholder="IMAP host" value="imap.gmail.com"><input id="sh" placeholder="SMTP host" value="smtp.gmail.com"><p id="r" class="muted"></p><button id="t">Connect</button> <button class="p" id="nx">Finish</button>`;
      $("#t").onclick = async () => { try { $("#r").textContent = await invoke("connect_mail", { email: $("#em").value.trim(), password: $("#pw").value, imapHost: $("#ih").value.trim(), imapPort: 993, smtpHost: $("#sh").value.trim(), smtpPort: 465 }); } catch (e) { $("#r").textContent = String(e); } }; },
  ];
  for (let i = 0; i < steps.length; i++) { steps[i](); await new Promise(res => $("#nx").onclick = res); if (i === 2) await invoke("seed_interests", { categories: [...picked] }); }
  await invoke("set_pref", { key: "onboarded", value: "1" }); w.style.display = "none"; await refreshState(); show("today");
}
// Morning briefing: once a day from the chosen hour (while the app is running) it writes the briefing and shows a notification.
setInterval(async () => { try { if (await invoke("morning_due")) { await writeBriefing(); if (brief && "Notification" in window) { if (Notification.permission === "default") await Notification.requestPermission(); new Notification("Good morning", { body: await invoke("briefing_preview", { text: brief }) }); } } } catch (_) {} }, 60000);
refreshState().then(async () => { show("today"); await wizard(); });
