import { router } from "expo-router";
import { useState } from "react";
import { Text, View } from "react-native";
import { SignOutButton } from "@/components/sign-out-button";
import {
  Button,
  ErrorText,
  PasswordField,
  Screen,
  colors,
} from "@/components/ui";
import { ApiError, accountApi } from "@/lib/api";
import { toUserMessage } from "@/lib/errors";
import { passwordPolicy } from "@/lib/identity";
import { useSession } from "@/lib/session-provider";

const EXPIRED =
  "Your temporary password has expired. Ask your Unit Admin to reset it.";

function Rule({
  testID,
  label,
  met,
}: {
  testID: string;
  label: string;
  met: boolean;
}) {
  return (
    <Text testID={testID} style={{ fontSize: 15, color: colors.text }}>
      {label}: {met ? "Met" : "Not met"}
    </Text>
  );
}

export default function ChangePassword() {
  const { ctx, client, refresh, setNotice } = useSession();
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [errors, setErrors] = useState<{
    current?: string;
    next?: string;
    confirm?: string;
    form?: string;
  }>({});
  const [busy, setBusy] = useState(false);
  const [expired, setExpired] = useState(false);

  if (!ctx || "noAccess" in ctx) return null;
  const forced = "mustChangePassword" in ctx;

  if (expired || (forced && ctx.expired)) {
    return (
      <Screen testID="change-password-screen">
        <Text
          testID="password-expired"
          accessibilityRole="alert"
          style={{ fontSize: 17, color: colors.text }}
        >
          {EXPIRED}
        </Text>
        <SignOutButton />
      </Screen>
    );
  }

  const policy = passwordPolicy(next, current || undefined);
  const checks = policy.ok
    ? { length: true, letter: true, digit: true, different: true }
    : policy.checks;
  const matches = next.length > 0 && next === confirm;

  async function onSubmit() {
    const e: typeof errors = {};
    if (!current) e.current = "Enter your current password";
    if (!policy.ok) e.next = policy.message;
    if (next !== confirm) e.confirm = "The two new passwords do not match";
    if (e.current || e.next || e.confirm) {
      setErrors(e);
      return;
    }
    setBusy(true);
    setErrors({});
    try {
      await accountApi.changePassword(client, current, next);
      // D14: Auth ends every session on a password change, so sign out locally and ask for a fresh sign-in.
      setNotice("password_changed");
      await client.auth.signOut({ scope: "local" });
      await refresh();
    } catch (err) {
      if (err instanceof ApiError && err.code === "expired") setExpired(true);
      else if (err instanceof ApiError && err.field === "current_password")
        setErrors({ current: err.message });
      else if (err instanceof ApiError && err.field === "new_password")
        setErrors({ next: err.message });
      else
        setErrors({
          form: err instanceof ApiError ? err.message : toUserMessage(err),
        });
    } finally {
      setBusy(false);
    }
  }

  return (
    <Screen testID="change-password-screen">
      <Text
        accessibilityRole="header"
        style={{ fontSize: 24, fontWeight: "700", color: colors.text }}
      >
        Change password
      </Text>
      {forced ? (
        <Text style={{ fontSize: 15, color: colors.muted }}>
          You signed in with a temporary password. Choose your own to continue.
        </Text>
      ) : null}
      <PasswordField
        label="Current password"
        testID="current-password"
        value={current}
        onChangeText={setCurrent}
        error={errors.current}
        autoComplete="current-password"
      />
      <PasswordField
        label="New password"
        testID="new-password"
        value={next}
        onChangeText={setNext}
        error={errors.next}
        autoComplete="new-password"
      />
      <PasswordField
        label="Confirm new password"
        testID="confirm-password"
        value={confirm}
        onChangeText={setConfirm}
        error={errors.confirm}
        autoComplete="new-password"
        onSubmitEditing={onSubmit}
      />
      <View accessibilityLabel="Password rules" style={{ gap: 2 }}>
        <Rule
          testID="rule-length"
          label="At least 10 characters"
          met={checks.length}
        />
        <Rule testID="rule-letter" label="A letter" met={checks.letter} />
        <Rule testID="rule-digit" label="A digit" met={checks.digit} />
        <Rule
          testID="rule-different"
          label="Different from the current password"
          met={checks.different && !!current ? current !== next : false}
        />
        <Rule
          testID="rule-match"
          label="Matches the confirmation"
          met={matches}
        />
      </View>
      {errors.form ? (
        <ErrorText testID="change-password-error">{errors.form}</ErrorText>
      ) : null}
      <Button
        title="Change password"
        testID="change-password-submit"
        onPress={onSubmit}
        disabled={busy}
        busy={busy}
      />
      {forced ? null : (
        <Button
          title="Back"
          variant="secondary"
          testID="change-password-back"
          onPress={() => router.replace("/home")}
        />
      )}
      {forced ? <SignOutButton /> : null}
    </Screen>
  );
}
