# everyday. website

Static site: no build step, no third-party requests, no framework.

```bash
cd site && python3 -m http.server 8811    # then open http://localhost:8811
```

- `index.html`, `privacy.html`, `css/style.css`, `js/main.js`.
- `js/config.js` holds the GitHub and download links (the download button points at the latest GitHub release).
- Light and dark follow the system; the switch in the nav overrides it and is remembered per browser.
- Paper texture is inline SVG noise. Torn edges are `clip-path` polygons generated in `js/main.js` from a fixed seed per section, so they look the same on every visit.
- `version.json` is read once a day by the app to show an update notice.
