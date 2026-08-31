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

// The copy-button handler that lived here served exactly one thing, the
// Remote Agent install one-liner, and went with it (T1175). Nothing on the
// page carries data-copy-target any more.

// The Remote Agent section used to fetch the relay's published agent manifest
// to show a standalone agent version and retarget a second download button.
// There is one Windows installer now (T1175) and it carries the agent, so the
// section links at #download and there is no separate version to report.
