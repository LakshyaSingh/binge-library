/* Binge Library site motion. GSAP + ScrollTrigger, scrubbed to scroll.
   With Reduced Motion on, nothing is pinned or scrubbed: CSS shows a plain page. */
(() => {
  const root = document.documentElement;
  const RM = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const hasGSAP = typeof window.gsap !== "undefined" && typeof window.ScrollTrigger !== "undefined";
  if (!hasGSAP) root.classList.remove("js");          // never leave content hidden if GSAP failed to load
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const small = () => innerWidth < 760;

  // ---------- Nav turns solid once you leave the top ----------
  const nav = $("#nav");
  const onScroll = () => nav.classList.toggle("solid", scrollY > 40);
  addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // ---------- Hero rotator ----------
  const rots = $$(".rot");
  let ri = 0;
  setInterval(() => {
    if (document.hidden || scrollY > innerHeight) return;
    const cur = rots[ri];
    ri = (ri + 1) % rots.length;
    cur.classList.remove("is-on");
    cur.classList.add("is-off");
    rots[ri].classList.remove("is-off");
    rots[ri].classList.add("is-on");
    setTimeout(() => cur.classList.remove("is-off"), 750);
  }, 2600);

  // ---------- Floating posters ----------
  // [x%, y%, width px, blur px]. Kept out of the band where the headline and buttons sit.
  const LAYOUT = [
    [5, 13, 76, 0], [15, 33, 56, 2], [8, 60, 88, 0], [4, 86, 60, 1.5], [21, 9, 50, 2.5], [19, 79, 70, 0],
    [16, 52, 44, 3], [31, 93, 54, 1], [91, 15, 80, 0], [79, 7, 52, 2], [94, 45, 62, 1], [84, 31, 46, 3],
    [89, 70, 86, 0], [96, 90, 54, 2], [79, 89, 66, 0], [82, 55, 44, 2.5], [37, 6, 44, 3], [62, 7, 50, 2],
    [46, 95, 56, 1.5], [67, 94, 46, 2.5], [11, 96, 42, 3], [71, 13, 40, 3.5], [29, 15, 42, 3.5], [58, 89, 42, 3],
  ];
  const postersEl = $("#posters");
  const posters = LAYOUT.map(([x, y, w, b], i) => {
    const p = document.createElement("div");
    p.className = "poster";
    p.style.left = x + "%";
    p.style.top = y + "%";
    p.style.width = w + "px";
    p.dataset.depth = String(1 - b / 4);
    p.innerHTML = `<div class="par"><div class="flo" style="--d:${7 + (i * 1.7) % 6}s;--dl:-${(i * 0.9) % 5}s;--r1:${-4 + (i % 5)}deg;--r2:${3 - (i % 4)}deg"><img src="assets/posters/p${i + 1}.webp" alt="" style="filter:blur(${b}px);opacity:${b > 2 ? 0.55 : b > 0 ? 0.8 : 1}" decoding="async"></div></div>`;
    postersEl.appendChild(p);
    return p;
  });
  if (small()) posters.forEach((p, i) => { if (i % 2) p.style.display = "none"; else p.style.width = parseFloat(p.style.width) * 0.72 + "px"; });

  // Gentle parallax with the pointer (skipped on touch and Reduced Motion).
  if (!RM && matchMedia("(pointer: fine)").matches) {
    addEventListener("pointermove", (e) => {
      if (scrollY > innerHeight * 0.2) return;
      const dx = e.clientX / innerWidth - 0.5, dy = e.clientY / innerHeight - 0.5;
      posters.forEach((p) => {
        const d = parseFloat(p.dataset.depth) * 26;
        p.firstElementChild.style.transform = `translate3d(${(-dx * d).toFixed(1)}px, ${(-dy * d).toFixed(1)}px, 0)`;
      });
    }, { passive: true });
  }

  // ---------- Word-by-word pitch ----------
  const reveal = $("#reveal");
  const words = reveal.textContent.trim().split(/\s+/);
  reveal.innerHTML = words.map((w) => `<span class="w${/^(Native|Private|Free)\.$/.test(w) ? " hi" : ""}">${w}</span>`).join(" ");
  const wordEls = $$(".w", reveal);

  // ---------- Film play button ----------
  const video = $("#filmVideo"), frame = video.closest(".film-frame");
  $("#playBtn").addEventListener("click", () => { video.controls = true; video.play(); });
  video.addEventListener("play", () => frame.classList.add("playing"));
  video.addEventListener("pause", () => frame.classList.remove("playing"));
  video.addEventListener("ended", () => frame.classList.remove("playing"));

  // ---------- FAQ: animate open and closed ----------
  $$(".faq details").forEach((d) => {
    const a = $(".a", d), s = $("summary", d);
    s.addEventListener("click", (e) => {
      if (RM) return;
      e.preventDefault();
      if (d.open) {
        const anim = a.animate([{ height: a.offsetHeight + "px", opacity: 1 }, { height: "0px", opacity: 0 }], { duration: 280, easing: "cubic-bezier(.2,.8,.2,1)" });
        anim.onfinish = () => { d.open = false; };
      } else {
        d.open = true;
        a.animate([{ height: "0px", opacity: 0 }, { height: a.scrollHeight + "px", opacity: 1 }], { duration: 340, easing: "cubic-bezier(.2,.8,.2,1)" });
      }
    });
  });

  if (!hasGSAP || RM) {
    wordEls.forEach((w) => w.classList.add("on"));
    $$("[data-count]").forEach((el) => { el.textContent = Number(el.dataset.count).toLocaleString(); });
    return;
  }

  const { gsap, ScrollTrigger } = window;
  gsap.registerPlugin(ScrollTrigger);

  // ---------- Hero: posters gather into the app window ----------
  const stage = $("#heroStage"), mac = $("#mac"), macShot = $(".mac-shot", mac);
  // Poster slots in the real library screenshot (fractions of the window), so the hand-off is seamless.
  const COLS = [0.155, 0.276, 0.396, 0.517, 0.637, 0.757, 0.878], ROWS = [0.088, 0.472], CW = 0.106, CH = 0.282;
  const slots = ROWS.flatMap((r) => COLS.map((c) => [c + CW / 2, r + CH / 2]));
  const visible = posters.filter((p) => p.style.display !== "none");
  const gather = visible.slice(0, slots.length);
  const leave = visible.slice(slots.length);

  gsap.set(posters, { xPercent: -50, yPercent: -50 });

  // The window's untransformed layout box (its wrapper fills the stage, so offsets are stage coordinates).
  const macBox = () => ({ w: mac.offsetWidth, h: mac.offsetHeight, left: mac.offsetLeft, top: mac.offsetTop });
  const startCenter = (p) => ({ x: p.offsetLeft, y: p.offsetTop });   // left/top are the centre (xPercent -50)

  const hero = gsap.timeline({
    defaults: { ease: "power2.inOut" },
    scrollTrigger: { trigger: stage, start: "top top", end: "+=320%", pin: true, scrub: 1.2, invalidateOnRefresh: true,
      onUpdate: (st) => postersEl.classList.toggle("gathering", st.progress > 0.04) },
  });
  hero.to("#heroCopy", { y: -90, autoAlpha: 0, filter: "blur(12px)", duration: 0.24, ease: "power1.in" }, 0)
      .to("#scrollCue", { autoAlpha: 0, duration: 0.08 }, 0)
      .fromTo(mac, { autoAlpha: 0, scale: 0.82, y: 70 }, { autoAlpha: 1, scale: 1, y: 0, duration: 0.36 }, 0.12)
      .to("#cap1", { autoAlpha: 1, duration: 0.08 }, 0.22)
      .to("#cap1", { autoAlpha: 0, duration: 0.08 }, 0.6);
  gather.forEach((p, i) => {
    const img = $("img", p);
    hero.to(p, {
      x: () => { const b = macBox(); return b.left + slots[i][0] * b.w - startCenter(p).x; },
      y: () => { const b = macBox(); return b.top + slots[i][1] * b.h - startCenter(p).y; },
      scale: () => (CW * macBox().w) / p.offsetWidth,
      rotation: 0, duration: 0.46,
    }, 0.14 + i * 0.012)
      .to(img, { filter: "blur(0px)", opacity: 1, borderRadius: 4, duration: 0.3 }, 0.18 + i * 0.012);
  });
  hero.to(leave, { autoAlpha: 0, scale: 0.5, duration: 0.25, stagger: 0.01 }, 0.12)
      .to(macShot, { opacity: 1, duration: 0.14, ease: "none" }, 0.7)
      .to(gather, { autoAlpha: 0, duration: 0.08, ease: "none" }, 0.83)
      .to("#cap2", { autoAlpha: 1, duration: 0.08 }, 0.74)
      .to({}, { duration: 0.12 });

  // ---------- Pitch lights up word by word ----------
  ScrollTrigger.create({
    trigger: ".pitch", start: "center center", end: "+=140%", pin: true, scrub: 1,
    onUpdate: (st) => {
      const n = Math.round(st.progress * wordEls.length);
      wordEls.forEach((w, i) => w.classList.toggle("on", i < n));
    },
  });

  // ---------- Feature stage ----------
  // The same seven scenes and timeline everywhere. Phones get their own portrait layout
  // (CSS, under 760px) on a 360×560 stage instead of the 860×500 desktop one shrunk to 40%.
  const mm = gsap.matchMedia();
  mm.add({ phone: "(max-width: 759px)", wide: "(min-width: 760px)" }, (ctx) => {
  const PHONE = ctx.conditions.phone;
  const BW = PHONE ? 360 : 860, BH = PHONE ? 560 : 500;
  const stageEl = $("#stage"), wrap = $("#stageWrap");
  // A sizing box, so the scaled stage takes up its scaled size in the layout.
  let box = stageEl.parentElement;
  if (!box.classList.contains("stage-box")) {
    box = document.createElement("div");
    box.className = "stage-box";
    box.style.position = "relative";
    stageEl.parentNode.insertBefore(box, stageEl);
    box.appendChild(stageEl);
  }
  stageEl.style.position = "absolute";
  stageEl.style.left = "0"; stageEl.style.top = "0";
  stageEl.style.transformOrigin = "0 0";
  // Phones fire resize when the address bar slides in and out; only refit when the width changes.
  let lastW = 0;
  const fit = () => {
    if (PHONE && innerWidth === lastW) return;
    lastW = innerWidth;
    const s = PHONE
      ? Math.min(1, (innerWidth - 20) / BW, (innerHeight - 190) / BH)
      : Math.min(1, (innerWidth - 32) / BW, (innerHeight - 250) / BH);
    stageEl.style.transform = `scale(${s})`;
    box.style.width = BW * s + "px";
    box.style.height = BH * s + "px";
  };
  fit();
  addEventListener("resize", fit);

  const scenes = $$(".scene", stageEl), caps = $$(".caption"), dots = $$(".steps li");
  const N = scenes.length;
  const ft = gsap.timeline({
    defaults: { ease: "power2.out" },
    scrollTrigger: {
      trigger: wrap, start: "top top", end: `+=${N * 170}%`, pin: true, scrub: 1.2,
      onUpdate: (st) => { const k = Math.min(N - 1, Math.floor(st.progress * N)); dots.forEach((d, i) => d.classList.toggle("on", i === k)); },
    },
  });
  const show = (i) => {
    const b = i;
    ft.fromTo(scenes[i], { autoAlpha: 0, y: 40, scale: 0.97 }, { autoAlpha: 1, y: 0, scale: 1, duration: 0.16 }, b + 0.02)
      .fromTo(caps[i], { autoAlpha: 0, y: 16 }, { autoAlpha: 1, y: 0, duration: 0.14 }, b + 0.05);
    if (i < N - 1) {
      ft.to(scenes[i], { autoAlpha: 0, y: -40, scale: 0.98, duration: 0.13, ease: "power1.in" }, b + 0.87)
        .to(caps[i], { autoAlpha: 0, y: -12, duration: 0.1, ease: "power1.in" }, b + 0.87);
    }
  };
  // A tween whose progress drives a class or text, so it reverses cleanly when scrolling back up.
  const state = (at, dur, fn) => { const o = { v: 0 }; ft.to(o, { v: 1, duration: dur, ease: "none", onUpdate: () => fn(o.v) }, at); };

  // s1: a screenshot drops in, gets read, titles pop out
  show(0);
  const shot = $("#s1shot"), drop = $("#s1drop");
  ft.to(shot, {
    x: () => drop.offsetLeft + drop.offsetWidth / 2 - (shot.offsetLeft + shot.offsetWidth / 2),
    y: () => drop.offsetTop + drop.offsetHeight / 2 - (shot.offsetTop + shot.offsetHeight / 2),
    scale: 0.8, rotation: -2, duration: 0.24, ease: "power2.inOut",
  }, 0.2)
    // The drop zone's prompt clears as the screenshot arrives, so it never sits on top of it.
    .to(["#s1drop svg", "#s1drop span"], { autoAlpha: 0, duration: 0.06, ease: "none" }, 0.3)
    .to(drop, { borderColor: "rgba(59,140,255,0.8)", backgroundColor: "rgba(59,140,255,0.08)", duration: 0.08 }, 0.36)
    .fromTo("#s1scan", { autoAlpha: 0, y: -70 }, { autoAlpha: 1, y: () => shot.offsetHeight, duration: 0.2, ease: "none" }, 0.44)
    .to("#s1scan", { autoAlpha: 0, duration: 0.04 }, 0.64)
    .to(shot, { autoAlpha: 0.25, duration: 0.1 }, 0.64)
    .fromTo("#s1found .pill", { autoAlpha: 0, y: 26, scale: 0.7 }, { autoAlpha: 1, y: 0, scale: 1, duration: 0.12, stagger: 0.035, ease: "back.out(1.8)" }, 0.62);

  // s2: posters get their services
  show(1);
  ft.fromTo(".sp", { autoAlpha: 0, y: 40 }, { autoAlpha: 1, y: 0, duration: 0.14, stagger: 0.03 }, 1.08)
    .fromTo(".sp .badge", { scale: 0, rotation: -30 }, { scale: 1, rotation: 0, duration: 0.12, stagger: 0.04, ease: "back.out(2.2)" }, 1.32)
    .fromTo("#s2services img", { autoAlpha: 0, y: 14 }, { autoAlpha: 1, y: 0, duration: 0.08, stagger: 0.02 }, 1.55);

  // s3: the cursor clicks "Open in Apple TV"
  show(2);
  ft.fromTo("#s3cursor", { autoAlpha: 0, left: "72%", top: "92%" }, { autoAlpha: 1, left: "21.6%", top: "70%", duration: 0.26, ease: "power2.inOut" }, 2.18)
    .to("#s3cursor", { scale: 0.82, duration: 0.03, yoyo: true, repeat: 1 }, 2.46)
    .fromTo("#s3ring", { autoAlpha: 0, scale: 1.3 }, { autoAlpha: 1, scale: 1, duration: 0.1, ease: "back.out(2)" }, 2.48)
    .fromTo("#s3toast", { autoAlpha: 0, y: 20 }, { autoAlpha: 1, y: 0, duration: 0.1 }, 2.58);

  // s4: Season 1 ticks, and the show lands in both lists
  show(3);
  const chips = $$("#s4chips .chip"), lists = $$("#s4lists .list-pill");
  ft.fromTo("#s4note", { autoAlpha: 0 }, { autoAlpha: 0, duration: 0.01 }, 3.0);
  state(3.3, 0.04, (v) => chips[0].classList.toggle("on", v > 0.5));
  ft.to("#s4note", { autoAlpha: 1, duration: 0.08 }, 3.4);
  state(3.52, 0.04, (v) => lists[0].classList.toggle("on", v > 0.5));
  state(3.6, 0.04, (v) => lists[1].classList.toggle("on", v > 0.5));

  // s5: a notification arrives, then settles on the Updates page
  show(4);
  ft.fromTo("#s5notif", { autoAlpha: 0, x: 140 }, { autoAlpha: 1, x: 0, duration: 0.14, ease: "back.out(1.4)" }, 4.15)
    .fromTo("#s5updates", { autoAlpha: 0, y: 40 }, { autoAlpha: 1, y: 0, duration: 0.14 }, 4.42)
    .fromTo("#s5updates .up-row", { autoAlpha: 0, x: -20 }, { autoAlpha: 1, x: 0, duration: 0.08, stagger: 0.05 }, 4.5)
    .to("#s5notif", { autoAlpha: 0, y: 30, scale: 0.92, duration: 0.12, ease: "power1.in" }, 4.66);

  // s6: picks fan in, a thumbs-down swaps one out
  show(5);
  const recX = PHONE ? [10, 126, 242] : [110, 335, 560];
  gsap.set(["#s6a", "#s6b", "#s6c", "#s6d"], { left: (i) => recX[Math.min(i, 2) === i ? i : 1] });
  ft.fromTo(["#s6a", "#s6b", "#s6c"], { autoAlpha: 0, y: 60, rotation: (i) => (i - 1) * 9 }, { autoAlpha: 1, y: 0, rotation: (i) => (i - 1) * 3, duration: 0.14, stagger: 0.05, ease: "back.out(1.3)" }, 5.12)
    .fromTo("#s6d", { autoAlpha: 0, y: 70, rotation: 0 }, { autoAlpha: 0, duration: 0.01 }, 5.1)
    .fromTo("#s6thumb", { autoAlpha: 0, scale: 0.5 }, { autoAlpha: 1, scale: 1, duration: 0.07, ease: "back.out(2)" }, 5.42)
    .to("#s6b", { y: -70, rotation: 14, autoAlpha: 0, duration: 0.12, ease: "power2.in" }, 5.54)
    .to("#s6d", { autoAlpha: 1, y: 0, duration: 0.14, ease: "back.out(1.3)" }, 5.66);

  // s7: an agent adds a title, and it lands in the library
  show(6);
  ft.fromTo("#s7a", { autoAlpha: 0, y: 20, scale: 0.9 }, { autoAlpha: 1, y: 0, scale: 1, duration: 0.1 }, 6.12)
    .fromTo("#s7t", { autoAlpha: 0, x: -10 }, { autoAlpha: 1, x: 0, duration: 0.08 }, 6.26)
    .fromTo("#s7b", { autoAlpha: 0, y: 20, scale: 0.9 }, { autoAlpha: 1, y: 0, scale: 1, duration: 0.1 }, 6.38)
    .fromTo("#s7mini", { autoAlpha: 0, y: 30 }, { autoAlpha: 1, y: 0, duration: 0.1 }, 6.14)
    .fromTo("#s7new", { autoAlpha: 0, x: PHONE ? -40 : -260, y: PHONE ? -170 : 60, scale: 0.6, rotation: -10 }, { autoAlpha: 1, x: 0, y: 0, scale: 1, rotation: 0, duration: 0.2, ease: "power3.out" }, 6.52)
    .to({}, { duration: 0.3 }, 6.72);
    return () => removeEventListener("resize", fit);
  });

  // ---------- Things that rise into view ----------
  ScrollTrigger.batch("[data-rise]", {
    start: "top 88%",
    onEnter: (els) => gsap.to(els, { autoAlpha: 1, y: 0, duration: 0.9, stagger: 0.08, ease: "power3.out", overwrite: true }),
  });

  // ---------- Year in Review counters ----------
  $$("[data-count]").forEach((el) => {
    const to = Number(el.dataset.count), o = { v: 0 };
    ScrollTrigger.create({
      trigger: el, start: "top 85%", once: true,
      onEnter: () => gsap.to(o, { v: to, duration: 1.8, ease: "power3.out", onUpdate: () => { el.textContent = Math.round(o.v).toLocaleString(); } }),
    });
  });

  // Layout settles once images have their sizes.
  addEventListener("load", () => ScrollTrigger.refresh());
})();
