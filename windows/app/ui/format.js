// Shared by the real UI and its browser harness. All content is escaped before adding our own markup.
(function (root) {
  const esc = value => String(value ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const skim = value => esc(value)
    .replace(/&lt;&lt;([uadpmnl])\|(.*?)&gt;&gt;/gs, (_, kind, content) =>
      /^[\s.…]*$/.test(content) ? "" : `<span class="${kind === "p" ? "pn" : kind}">${content}</span>`)
    .replace(/&lt;&lt;[uadpmnl]\|/g, "").replace(/&gt;&gt;/g, "");
  function sections(value) {
    const result = [];
    let heading = null, lines = [];
    const flush = () => {
      const body = lines.join("\n").trim();
      if (body) result.push({ heading, body });
      lines = [];
    };
    for (const line of String(value ?? "").split(/\r?\n/)) {
      if (line.trim().startsWith("## ")) {
        flush(); heading = line.trim().slice(3).replace(/^[ #:]+|[ #:]+$/g, "");
      } else lines.push(line);
    }
    flush(); return result;
  }
  const briefing = value => sections(value).map(section =>
    (section.heading ? `<h3 class="brief-heading">${esc(section.heading)}</h3>` : "") +
    section.body.split(/\n\s*\n/).map(p => `<p>${skim(p).replace(/\n/g, "<br>")}</p>`).join("")
  ).join("");
  const api = Object.freeze({ esc, skim, sections, briefing });
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.EverydayFormat = api;
})(globalThis);
