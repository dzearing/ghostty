// Smooth reveal on scroll
const observer = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("visible");
        observer.unobserve(entry.target);
      }
    });
  },
  { threshold: 0.1, rootMargin: "0px 0px -40px 0px" }
);

document.querySelectorAll(
  ".feature-card, .skill-step, .install-card, .download-card, .remote-card, .section-header"
).forEach((el) => {
  el.style.opacity = "0";
  el.style.transform = "translateY(20px)";
  el.style.transition = "opacity 0.5s ease, transform 0.5s ease";
  observer.observe(el);
});

const style = document.createElement("style");
style.textContent = `.visible { opacity: 1 !important; transform: translateY(0) !important; }`;
document.head.appendChild(style);

document.querySelectorAll(".feature-card").forEach((card, i) => {
  card.style.transitionDelay = `${i * 0.08}s`;
});

document.querySelectorAll(".skill-step").forEach((step, i) => {
  step.style.transitionDelay = `${i * 0.15}s`;
});

// Nav background on scroll
const nav = document.querySelector("nav");
window.addEventListener("scroll", () => {
  nav.style.background = window.scrollY > 60
    ? "rgba(10, 10, 12, 0.92)"
    : "rgba(10, 10, 12, 0.7)";
}, { passive: true });

// Copy buttons (Remote Agent install one-liner)
document.querySelectorAll(".copy-btn[data-copy-target]").forEach((btn) => {
  btn.addEventListener("click", () => {
    const src = document.getElementById(btn.dataset.copyTarget);
    if (!src) return;
    const text = src.textContent.trim();
    const done = () => {
      btn.textContent = "Copied!";
      btn.classList.add("copied");
      setTimeout(() => {
        btn.textContent = "Copy";
        btn.classList.remove("copied");
      }, 1600);
    };
    const fallback = () => {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); done(); } catch (e) { /* ignore */ }
      document.body.removeChild(ta);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, fallback);
    } else {
      fallback();
    }
  });
});

// Current Windows agent version — best-effort; silent if unreachable.
// (Relay serves /dl/version.json with Access-Control-Allow-Origin: *.)
(() => {
  const el = document.getElementById("agent-version");
  if (!el) return;
  fetch("https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com/dl/version.json", { cache: "no-store" })
    .then((r) => (r.ok ? r.json() : null))
    .then((v) => {
      const win = v && v["windows-x86_64"];
      if (win && win.version) el.textContent = " Current version: " + win.version + ".";
    })
    .catch(() => { /* version info unavailable */ });
})();
