import React from "react";
import { Box, Text } from "ink";
import type { AccountStatusData, BillingStatusData } from "../../../packages/contracts/src/index";
import { formatBytes, formatClockMs, progressBar } from "./format";

export type AccountStatus = AccountStatusData | "loading" | "error" | undefined;

// Account / status screen: the dashboard's hub entry for "who am I, how much
// have I used, where's my local data". Data comes from the account-status
// contract (logged-in user + billing/usage + local store).
export function AccountView({ status }: { status?: AccountStatus }): React.ReactElement {
  return (
    <Box flexDirection="column" paddingX={1}>
      <Text dimColor>‹ Account</Text>

      {status === "loading" || status === undefined ? (
        <Box marginTop={1}>
          <Text dimColor>Loading account…</Text>
        </Box>
      ) : status === "error" ? (
        <Box marginTop={1}>
          <Text color="red">Couldn't load account status</Text>
        </Box>
      ) : !status.loggedIn ? (
        <Box marginTop={1} flexDirection="column">
          <Text color="yellow">Not signed in</Text>
          <Text dimColor>{`origin  ${status.origin}`}</Text>
          <Text dimColor>Run `recappi auth login` to sign in.</Text>
        </Box>
      ) : (
        <AccountBody status={status} />
      )}

      <Box marginTop={1}>
        <Text dimColor>r refresh · esc back · q quit</Text>
      </Box>
    </Box>
  );
}

function AccountBody({ status }: { status: AccountStatusData }): React.ReactElement {
  return (
    <>
      <Box marginTop={1} flexDirection="column">
        <Text bold color="green">
          {status.email ?? status.userId ?? "Signed in"}
        </Text>
        {status.email && status.userId ? <Text dimColor>{status.userId}</Text> : null}
        <Text dimColor>{`origin  ${status.origin}`}</Text>
      </Box>

      {status.billing ? <Usage billing={status.billing} /> : null}

      <Box marginTop={1} flexDirection="column">
        <Text bold>Local store</Text>
        <Text dimColor wrap="truncate-middle">{status.localStore.path}</Text>
        <Text dimColor>
          {`${status.localStore.accountScopedArtifacts} artifact${status.localStore.accountScopedArtifacts === 1 ? "" : "s"} for this account`}
          {status.localStore.unattributedArtifacts > 0
            ? ` · ${status.localStore.unattributedArtifacts} unattributed`
            : ""}
        </Text>
      </Box>
    </>
  );
}

function Usage({ billing }: { billing: BillingStatusData }): React.ReactElement {
  const minutesCap = billing.minutesCap;
  const minutesUsed = billing.minutesUsed;
  const storageCap = billing.storageCapBytes;
  return (
    <Box marginTop={1} flexDirection="column">
      <Text>
        <Text dimColor>Plan </Text>
        <Text bold>{billing.tier}</Text>
      </Text>

      <Text>
        <Text dimColor>Minutes </Text>
        {minutesCap != null ? (
          <Text color={billing.isOverMinutes ? "red" : "cyan"}>
            {`${progressBar(minutesUsed / Math.max(1, minutesCap), 12)} `}
          </Text>
        ) : null}
        <Text color={billing.isOverMinutes ? "red" : undefined}>
          {`${Math.round(minutesUsed)}`}
        </Text>
        <Text dimColor>{` / ${minutesCap != null ? Math.round(minutesCap) : "∞"} min`}</Text>
        <Text dimColor>{`   (batch ${Math.round(billing.batchMinutesUsed)} · live ${Math.round(billing.realtimeMinutesUsed)})`}</Text>
      </Text>

      <Text>
        <Text dimColor>Storage </Text>
        {storageCap != null ? (
          <Text color={billing.isOverStorage ? "red" : "cyan"}>
            {`${progressBar(billing.storageBytes / Math.max(1, storageCap), 12)} `}
          </Text>
        ) : null}
        <Text color={billing.isOverStorage ? "red" : undefined}>{formatBytes(billing.storageBytes)}</Text>
        <Text dimColor>{` / ${storageCap != null ? formatBytes(storageCap) : "∞"}`}</Text>
      </Text>

      {billing.isOverMinutes || billing.isOverStorage ? (
        <Text color="red">
          {billing.isOverMinutes ? "Over minutes limit. " : ""}
          {billing.isOverStorage ? "Over storage limit." : ""}
        </Text>
      ) : null}

      <Text dimColor>{`Period ${periodText(billing)}`}</Text>
    </Box>
  );
}

function periodText(billing: BillingStatusData): string {
  // periodStart/End are epoch seconds or ms; show a coarse remaining window.
  const remainingMs = epochToMs(billing.periodEnd) - Date.now();
  if (!Number.isFinite(remainingMs) || remainingMs <= 0) return "—";
  const days = Math.floor(remainingMs / 86_400_000);
  if (days >= 1) return `${days}d left`;
  return `${formatClockMs(remainingMs)} left`;
}

function epochToMs(value: number): number {
  return value > 1e12 ? value : value * 1000;
}
