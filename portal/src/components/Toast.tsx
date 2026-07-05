/** Minimal toast system: success/error feedback for mutations. */

import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";

interface Toast {
  id: number;
  kind: "ok" | "error";
  text: string;
}

interface ToastApi {
  ok: (text: string) => void;
  error: (text: string) => void;
}

const ToastContext = createContext<ToastApi | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const nextId = useRef(1);

  const push = useCallback((kind: Toast["kind"], text: string) => {
    const id = nextId.current++;
    setToasts((ts) => [...ts, { id, kind, text }]);
    window.setTimeout(
      () => setToasts((ts) => ts.filter((t) => t.id !== id)),
      kind === "error" ? 6000 : 3200,
    );
  }, []);

  const apiValue = useMemo<ToastApi>(
    () => ({
      ok: (text) => push("ok", text),
      error: (text) => push("error", text),
    }),
    [push],
  );

  return (
    <ToastContext.Provider value={apiValue}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {toasts.map((t) => (
          <div key={t.id} className={`toast ${t.kind}`}>
            <span className="toast-dot" />
            <span>{t.text}</span>
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}

export function useToast(): ToastApi {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error("useToast outside ToastProvider");
  return ctx;
}
