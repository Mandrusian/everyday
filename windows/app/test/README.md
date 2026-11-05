# UI harness
`stub.js` stands in for Rust commands. The harness loads the production formatting and UI scripts directly, so it cannot silently test an old copied script.

From `windows/app`, run:

```bash
python3 -m http.server 8790 --bind 127.0.0.1
```

Open http://127.0.0.1:8790/test/app.html. The copied HTML shell is kept in step with `ui/index.html` (only script paths differ).

Formatting regression checks (no browser dependency):

```bash
node --test test/*.test.cjs
```

Exercise Today, section headings and highlights, handled notices, tasks, inbox, assistant, news, and Settings. This is not a substitute for running the Tauri app on Windows.
