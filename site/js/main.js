import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { config } from './config.js';

const gsap = window.gsap, ScrollTrigger = window.ScrollTrigger;
gsap.registerPlugin(ScrollTrigger);
const root = document.documentElement;
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

// ---- Links that need real URLs (see config.js) ----
document.querySelectorAll('[data-buy]').forEach(a => { if (config.buyUrl) a.href = config.buyUrl; });
document.querySelectorAll('[data-repo]').forEach(a => { if (config.repoUrl) { a.href = config.repoUrl; a.target = '_blank'; a.rel = 'noopener'; } });
if (config.repoUrl) document.querySelectorAll('[data-repo-url]').forEach(s => s.textContent = config.repoUrl.replace('https://', ''));

// Never leave the visitor on the loading screen, even if the model is slow.
setTimeout(() => root.classList.add('loaded'), 5000);

// ---- Page chrome: nav background, progress bar, reveals ----
const nav = document.getElementById('nav');
const bar = document.querySelector('.progress i');
function onScroll() {
  nav.classList.toggle('solid', scrollY > 40);
  const max = document.documentElement.scrollHeight - innerHeight;
  bar.style.transform = `scaleX(${max > 0 ? scrollY / max : 0})`;
}
addEventListener('scroll', onScroll, { passive: true }); onScroll();
const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }), { threshold: 0.18, rootMargin: '0px 0px -6% 0px' });
document.querySelectorAll('.reveal').forEach(el => io.observe(el));

// ---- 3D stage (Pattern 1: Three.js layer + GSAP ScrollTrigger layer + HTML layer) ----
const canvas = document.getElementById('stage');
let renderer;
try {
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, powerPreference: 'high-performance' });
} catch (e) { root.classList.add('no-webgl', 'loaded'); }

if (renderer) {
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  renderer.outputColorSpace = THREE.SRGBColorSpace;

  const scene = new THREE.Scene();
  const pmrem = new THREE.PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
  scene.environmentIntensity = 0.85;
  const key = new THREE.DirectionalLight(0xffe3cf, 2.2); key.position.set(3, 4, 5); scene.add(key);
  const rim = new THREE.DirectionalLight(0xd97757, 1.4); rim.position.set(-4, -1, -3); scene.add(rim);

  const camera = new THREE.PerspectiveCamera(30, 1, 0.1, 50);
  camera.position.set(0, 0, 8);

  const icon = new THREE.Group(); scene.add(icon);       // moved and spun by scroll
  const bob = new THREE.Group(); icon.add(bob);          // idle float and pointer tilt
  const SIZE = 2.1;                                      // icon width in world units

  new GLTFLoader().load('assets/everyday-3d-icon.glb', gltf => {
    const model = gltf.scene;
    const box = new THREE.Box3().setFromObject(model);
    const size = box.getSize(new THREE.Vector3()), c = box.getCenter(new THREE.Vector3());
    model.position.sub(c);
    const s = SIZE / Math.max(size.x, size.y);
    model.scale.setScalar(s);
    bob.add(model);
    root.classList.add('loaded');
    buildTimeline();
    ScrollTrigger.refresh();
  }, undefined, () => { root.classList.add('no-webgl', 'loaded'); });

  // Poses come from each section's data-pose="x y rotY rotX scale" (x is a fraction of half the visible width).
  const poses = [...document.querySelectorAll('[data-pose]')].map(el => {
    const [x, y, ry, rx, s] = el.dataset.pose.split(' ').map(Number);
    return { el, x, y, ry, rx, s };
  });
  const state = { x: 0, y: 0, ry: 0, rx: 0, s: 1 };
  if (poses[0]) Object.assign(state, poses[0]);

  function buildTimeline() {
    if (reduce) { Object.assign(state, poses[0] || {}); return; }
    const tl = gsap.timeline({ scrollTrigger: { trigger: 'main', start: 'top top', end: 'bottom bottom', scrub: 1.1 } });
    // Each section gets one segment: ease from the previous pose to this one, then hold.
    poses.slice(1).forEach(p => {
      tl.to(state, { x: p.x, y: p.y, ry: p.ry, rx: p.rx, s: p.s, duration: 1, ease: 'power2.inOut' });
      tl.to(state, { duration: 0.6 });
    });
  }

  const pointer = { x: 0, y: 0, tx: 0, ty: 0 };
  addEventListener('pointermove', e => { pointer.tx = (e.clientX / innerWidth - 0.5) * 2; pointer.ty = (e.clientY / innerHeight - 0.5) * 2; }, { passive: true });

  function resize() {
    const w = innerWidth, h = innerHeight;
    renderer.setSize(w, h, false);
    camera.aspect = w / h; camera.updateProjectionMatrix();
  }
  addEventListener('resize', resize); resize();

  const clock = new THREE.Clock();
  function frame() {
    const t = clock.getElapsedTime();
    const halfH = Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)) * camera.position.z, halfW = halfH * camera.aspect;
    const narrow = innerWidth < 860;
    pointer.x += (pointer.tx - pointer.x) * 0.05; pointer.y += (pointer.ty - pointer.y) * 0.05;
    icon.position.set(narrow ? state.x * halfW * 0.25 : state.x * halfW, (narrow ? halfH * 0.42 : state.y * halfH) , 0);
    icon.scale.setScalar(state.s * (narrow ? 0.62 : 1) * Math.min(1, halfW / 3.2 + 0.35));
    icon.rotation.set(state.rx, state.ry, 0);
    if (!reduce) {
      bob.position.y = Math.sin(t * 0.9) * 0.07;
      bob.rotation.set(pointer.y * 0.18 + Math.sin(t * 0.5) * 0.03, pointer.x * 0.28 + Math.sin(t * 0.7) * 0.05, Math.sin(t * 0.6) * 0.015);
    }
    renderer.render(scene, camera);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) clock.getDelta(); });
}

// Pricing cards: a little tilt toward the pointer.
if (!reduce) document.querySelectorAll('.card').forEach(card => {
  card.addEventListener('pointermove', e => {
    const r = card.getBoundingClientRect();
    const x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
    card.style.transform = `perspective(800px) rotateX(${(-y * 5).toFixed(2)}deg) rotateY(${(x * 6).toFixed(2)}deg) translateY(-4px)`;
  });
  card.addEventListener('pointerleave', () => { card.style.transform = ''; });
});
