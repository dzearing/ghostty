/** Accessible-enough modal dialog: Escape closes, overlay click closes,
 * focus moves in on open. Small by design — no portal lib needed. */

import { useEffect, useRef, type ReactNode } from "react";

interface DialogProps {
  title: string;
  onClose: () => void;
  children: ReactNode;
  footer?: ReactNode;
}

export function Dialog({ title, onClose, children, footer }: DialogProps) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    // Focus the first focusable control (or the dialog) on open.
    const first = ref.current?.querySelector<HTMLElement>(
      "input, textarea, select, button",
    );
    first?.focus();
    return () => document.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div
      className="dlg-overlay"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="dlg" role="dialog" aria-modal="true" aria-label={title} ref={ref}>
        <div className="dlg-head">
          <div className="dlg-title">{title}</div>
          <button className="icon-btn" onClick={onClose} aria-label="Close">
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
              <path
                d="M3 3l8 8M11 3l-8 8"
                stroke="currentColor"
                strokeWidth="1.5"
                strokeLinecap="round"
              />
            </svg>
          </button>
        </div>
        <div className="dlg-body">{children}</div>
        {footer && <div className="dlg-foot">{footer}</div>}
      </div>
    </div>
  );
}
