import { lazy, Suspense } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { AuthProvider, useAuth } from "./auth/AuthContext";
import { ToastProvider } from "./components/Toast";
import { AppShell } from "./shell/AppShell";
import { CheckingPage, NotAdminPage, SignInPage } from "./shell/GatePages";
import { isApiError } from "./api/client";

// Route-level code splitting: the dashboard pulls in Recharts, which stays
// out of the initial bundle this way.
const DashboardPage = lazy(() => import("./pages/DashboardPage"));
const AttemptsPage = lazy(() => import("./pages/AttemptsPage"));
const AccountsPage = lazy(() => import("./pages/AccountsPage"));
const AccountDetailPage = lazy(() => import("./pages/AccountDetailPage"));
const InvitesPage = lazy(() => import("./pages/InvitesPage"));

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 10_000,
      retry: (failureCount, error) => {
        // Auth failures are terminal — retrying a 401/403 cannot succeed.
        if (isApiError(error) && (error.status === 401 || error.status === 403))
          return false;
        return failureCount < 2;
      },
    },
  },
});

function Gate() {
  const { status } = useAuth();

  switch (status) {
    case "loading":
    case "checking":
      return <CheckingPage />;
    case "signed-out":
      return <SignInPage />;
    case "not-admin":
      return <NotAdminPage />;
    case "ready":
      return (
        <AppShell>
          <Suspense fallback={null}>
            <Routes>
              <Route path="/" element={<DashboardPage />} />
              <Route path="/attempts" element={<AttemptsPage />} />
              <Route path="/accounts" element={<AccountsPage />} />
              <Route path="/accounts/:id" element={<AccountDetailPage />} />
              <Route path="/invites" element={<InvitesPage />} />
              <Route path="*" element={<Navigate to="/" replace />} />
            </Routes>
          </Suspense>
        </AppShell>
      );
  }
}

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <ToastProvider>
          <BrowserRouter
            // BASE_URL has a trailing slash ("/admin/"); React Router treats a
            // trailing-slash basename as NOT matching the bare "/admin"
            // location and silently renders nothing (prod strips the warning).
            // Strip it: "/" -> "" (root), "/admin/" -> "/admin".
            basename={import.meta.env.BASE_URL.replace(/\/$/, "")}
            future={{ v7_startTransition: true, v7_relativeSplatPath: true }}
          >
            <Gate />
          </BrowserRouter>
        </ToastProvider>
      </AuthProvider>
    </QueryClientProvider>
  );
}
