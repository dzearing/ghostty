import "@testing-library/jest-dom/vitest";

// jsdom lacks ResizeObserver (recharts) and matchMedia.
class RO {
  observe() {}
  unobserve() {}
  disconnect() {}
}
globalThis.ResizeObserver = globalThis.ResizeObserver ?? (RO as never);
