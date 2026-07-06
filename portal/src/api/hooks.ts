/**
 * React Query bindings for the admin API. Query keys are structured so
 * mutations can invalidate precisely; list data refetches on focus and on a
 * gentle interval so the dashboard/attempt feed feel live without hammering
 * the relay.
 */

import {
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { useAuth } from "../auth/AuthContext";
import type {
  AccountsQuery,
  AttemptsQuery,
  CreateInviteRequest,
  SignupMode,
} from "./types";

const LIVE = { refetchInterval: 20_000, refetchOnWindowFocus: true } as const;

export function useAttempts(q: AttemptsQuery = {}) {
  const { api } = useAuth();
  return useQuery({
    queryKey: ["attempts", q],
    queryFn: () => api.listAttempts(q),
    placeholderData: (prev) => prev, // keep rows while a filter refetches
    ...LIVE,
  });
}

export function useAccounts(q: AccountsQuery = {}) {
  const { api } = useAuth();
  return useQuery({
    queryKey: ["accounts", q],
    queryFn: () => api.listAccounts(q),
    placeholderData: (prev) => prev,
    ...LIVE,
  });
}

export function useAccountUsage(id: string) {
  const { api } = useAuth();
  return useQuery({
    queryKey: ["account-usage", id],
    queryFn: () => api.accountUsage(id),
    ...LIVE,
  });
}

export function useInvites() {
  const { api } = useAuth();
  return useQuery({
    queryKey: ["invites"],
    queryFn: () => api.listInvites(),
    ...LIVE,
  });
}

export function useSettings() {
  const { api } = useAuth();
  return useQuery({
    queryKey: ["settings"],
    queryFn: () => api.getSettings(),
    ...LIVE,
  });
}

/* ---- Mutations ---- */

function useInvalidate() {
  const qc = useQueryClient();
  return (...keys: string[]) => {
    for (const k of keys) void qc.invalidateQueries({ queryKey: [k] });
  };
}

export function useBlockAccount() {
  const { api } = useAuth();
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: ({ id, reason }: { id: string; reason: string }) =>
      api.blockAccount(id, reason),
    onSuccess: () => invalidate("accounts", "account-usage"),
  });
}

export function useUnblockAccount() {
  const { api } = useAuth();
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (id: string) => api.unblockAccount(id),
    onSuccess: () => invalidate("accounts", "account-usage"),
  });
}

export function useDeleteAccount() {
  const { api } = useAuth();
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (id: string) => api.deleteAccount(id),
    onSuccess: () => invalidate("accounts", "account-usage", "attempts"),
  });
}

export function useCreateInvite() {
  const { api } = useAuth();
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (req: CreateInviteRequest) => api.createInvite(req),
    onSuccess: () => invalidate("invites"),
  });
}

export function useRevokeInvite() {
  const { api } = useAuth();
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (code: string) => api.revokeInvite(code),
    onSuccess: () => invalidate("invites"),
  });
}

export function useUpdateSettings() {
  const { api } = useAuth();
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (mode: SignupMode) => api.putSettings(mode),
    onSuccess: () => invalidate("settings"),
  });
}
