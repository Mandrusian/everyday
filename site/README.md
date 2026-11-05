# everyday. website (draft)

Static site: no build step, no third-party requests. three.js 0.170.0 and GSAP 3.12.5 are vendored in `vendor/` (SHA-256 below).

```bash
cd site && python3 -m http.server 8765    # then open http://127.0.0.1:8765
```

## Before launch (TODO)
- `js/config.js`: set `repoUrl` and `buyUrl` (Lemon Squeezy or Stripe checkout link).
- `privacy.html`: fill in the contact address and have the text checked.
- `img/*.jpg` are real app screenshots that include third-party headlines and a personal city. Replace with staged ones.
- Open Graph image and favicon.
- Check pricing and claims against what is actually shipped (the page only describes built features).

## How the 3D scroll works
`js/main.js` follows the layered pattern: Three.js scene (canvas, fixed) · GSAP ScrollTrigger timeline (scrub) · HTML sections. Each `<section data-pose="x y rotY rotX scale">` defines where the icon sits; the timeline eases between poses. `x` is a fraction of half the visible width. On narrow screens the icon is kept small and near the top. `prefers-reduced-motion` disables scrubbing and idle motion; no WebGL hides the canvas.

## Vendored files
```
three.module.min.js  08fd7545d13d2c7fb65ab691530a802dafefd638596501854f267d0fb13c39e7
gsap.min.js          28033e449a31ebcc396e5be8b13b63152bf03094288fb5867034321927bce087
ScrollTrigger.min.js ad33c2df9ada8a663c2147357828f980d0b7ca731ef33eb3c6e4f327c3b2cda5
```
`vendor/addons/` holds GLTFLoader, BufferGeometryUtils and RoomEnvironment from three@0.170.0 `examples/jsm`.

## Model
`assets/everyday-3d-icon.glb` (143 KB, plain glTF 2.0, no Draco). Double sided: the back reads correctly, which the privacy section shows.
