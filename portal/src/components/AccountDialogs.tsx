/**
 * Destructive-action dialogs for accounts, shared by the list and detail
 * screens. Block asks for a reason; delete requires typing the account's
 * email (it revokes device credentials and severs live connections — the
 * dialog says so).
 */

import { useState } from "react";
import type { Account } from "../api/types";
import { useBlockAccount, useDeleteAccount } from "../api/hooks";
import { useToast } from "./Toast";
import { Dialog } from "./Dialog";

export function BlockDialog({
  account,
  onClose,
}: {
  account: Account;
  onClose: () => void;
}) {
  const [reason, setReason] = useState("");
  const block = useBlockAccount();
  const toast = useToast();

  const submit = () => {
    block.mutate(
      { id: account.id, reason: reason.trim() },
      {
        onSuccess: () => {
          toast.ok(`Blocked ${account.email}`);
          onClose();
        },
        onError: (e) => toast.error(`Block failed: ${e.message}`),
      },
    );
  };

  return (
    <Dialog
      title="Block account"
      onClose={onClose}
      footer={
        <>
          <button className="btn ghost" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn danger-solid"
            onClick={submit}
            disabled={block.isPending}
          >
            {block.isPending ? "Blocking…" : "Block account"}
          </button>
        </>
      }
    >
      <p>
        Block <strong>{account.email}</strong>? Their next sign-in is refused.
        Existing device tokens keep working until the account is deleted.
      </p>
      <div className="field">
        <label htmlFor="block-reason">Reason</label>
        <textarea
          id="block-reason"
          className="textarea"
          rows={2}
          placeholder="Why is this account being blocked? (shown on the account)"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
        />
        <span className="hint">Optional, but future-you will want one.</span>
      </div>
    </Dialog>
  );
}

export function DeleteDialog({
  account,
  onClose,
  onDeleted,
}: {
  account: Account;
  onClose: () => void;
  onDeleted?: () => void;
}) {
  const [confirm, setConfirm] = useState("");
  const del = useDeleteAccount();
  const toast = useToast();
  const match = confirm.trim().toLowerCase() === account.email.toLowerCase();

  const submit = () => {
    if (!match) return;
    del.mutate(account.id, {
      onSuccess: (res) => {
        toast.ok(
          `Deleted ${account.email} · ${res.devices_deleted} device${res.devices_deleted === 1 ? "" : "s"} revoked`,
        );
        onClose();
        onDeleted?.();
      },
      onError: (e) => toast.error(`Delete failed: ${e.message}`),
    });
  };

  return (
    <Dialog
      title="Delete account"
      onClose={onClose}
      footer={
        <>
          <button className="btn ghost" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn danger-solid"
            onClick={submit}
            disabled={!match || del.isPending}
          >
            {del.isPending ? "Deleting…" : "Delete permanently"}
          </button>
        </>
      }
    >
      <div className="callout">
        This permanently deletes <strong>{account.email}</strong> and all{" "}
        <strong>
          {account.device_count} enrolled device
          {account.device_count === 1 ? "" : "s"}
        </strong>
        . Device credentials are revoked and live connections are severed
        immediately. This cannot be undone.
      </div>
      <div className="field">
        <label htmlFor="del-confirm">
          Type <code>{account.email}</code> to confirm
        </label>
        <input
          id="del-confirm"
          className="input"
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          placeholder={account.email}
          autoComplete="off"
          onKeyDown={(e) => {
            if (e.key === "Enter") submit();
          }}
        />
      </div>
    </Dialog>
  );
}
