/* SunoFlow site — small, dependency-free interactions. */
(function () {
  "use strict";

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---- sticky header hairline ---- */
  var head = document.querySelector(".masthead");
  var onScroll = function () { head.classList.toggle("stuck", window.scrollY > 8); };
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  /* ---- the little waveform in the listening pill ---- */
  var wave = document.querySelector(".wave");
  if (wave) {
    var BARS = 26;
    var frag = document.createDocumentFragment();
    for (var i = 0; i < BARS; i++) {
      var t = i / (BARS - 1);
      var envelope = Math.sin(Math.PI * t);           // quiet at the edges
      var jitter = 0.55 + 0.45 * Math.sin(i * 1.7);   // deterministic wobble
      var bar = document.createElement("i");
      bar.style.setProperty("--h", Math.max(3, Math.round(22 * envelope * jitter)));
      bar.style.setProperty("--d", (i * 55) % 800 + "ms");
      frag.appendChild(bar);
    }
    wave.appendChild(frag);
  }

  /* ---- reveal on scroll ----
     The hidden state only exists once .anim-ready is set, so if any of this
     fails the content simply stays visible instead of disappearing. */
  var targets = document.querySelectorAll(".reveal");
  var revealAll = function () {
    targets.forEach(function (el) { el.classList.add("in"); });
  };

  if (!reduced && "IntersectionObserver" in window) {
    document.documentElement.classList.add("anim-ready");
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        e.target.classList.add("in");
        io.unobserve(e.target);
      });
    }, { rootMargin: "0px 0px -12% 0px", threshold: 0.05 });
    targets.forEach(function (el) { io.observe(el); });

    // Backstop: throttled or background renderers can starve the observer.
    setTimeout(revealAll, 2500);
  }

  /* ---- before / after dictation demo ---- */
  var TAKES = [
    {
      app: "Slack",
      raw: "um so i think we should <s>uh</s> push the launch to monday <s>you know</s> and then <s>like</s> tell the client once we've got the new numbers",
      clean: "I think we should push the launch to Monday, and then tell the client once we've got the new numbers."
    },
    {
      app: "Mail",
      raw: "hey priya <s>um</s> thanks for sending the deck over i've had a look <s>i mean</s> a proper look and <s>uh</s> i've left a few comments on slide four",
      clean: "Hey Priya — thanks for sending the deck over. I've had a proper look and left a few comments on slide four."
    },
    {
      app: "Notes",
      raw: "<s>so</s> the main thing from the call was that they want <s>um</s> a decision by friday and <s>like</s> they're happy with the pricing but <s>uh</s> not the timeline",
      clean: "The main thing from the call was that they want a decision by Friday. They're happy with the pricing, but not the timeline."
    }
  ];

  var slot = document.querySelector("[data-demo]");
  if (slot) {
    var rawEl = slot.querySelector("[data-raw]");
    var cleanEl = slot.querySelector("[data-clean]");
    var appEl = slot.querySelector("[data-app]");
    var lines = [rawEl, cleanEl];
    var idx = 0;

    // Opacity is set explicitly rather than left to an animation's fill mode,
    // so a throttled frame can never strand a line at zero.
    var paint = function () {
      var t = TAKES[idx];
      appEl.textContent = t.app;
      rawEl.innerHTML = t.raw.replace(/<s>(.*?)<\/s>/g, '<span class="fill">$1</span>');
      cleanEl.textContent = t.clean;
      lines.forEach(function (el) { el.style.opacity = "1"; });
    };

    var advance = function () {
      if (document.hidden) return;
      lines.forEach(function (el) { el.style.opacity = "0"; });
      setTimeout(function () {
        idx = (idx + 1) % TAKES.length;
        paint();
      }, 380);
    };

    paint();

    if (!reduced) {
      var timer = null;
      var start = function () { if (!timer) timer = setInterval(advance, 5400); };
      var stop = function () { clearInterval(timer); timer = null; };
      start();
      document.addEventListener("visibilitychange", function () {
        if (document.hidden) { stop(); return; }
        paint();   // never come back to a half-faded line
        start();
      });
    }
  }

  /* ---- year in the footer ---- */
  var y = document.querySelector("[data-year]");
  if (y) y.textContent = new Date().getFullYear();
})();
