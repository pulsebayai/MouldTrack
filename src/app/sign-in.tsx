import { Redirect } from "expo-router";
import { useState } from "react";
import { Text } from "react-native";
import {
  Button,
  ErrorText,
  Field,
  PasswordField,
  Screen,
  colors,
} from "@/components/ui";
import { appVersionLabel } from "@/lib/app-version";
import { toUserMessage } from "@/lib/errors";
import { normalisePhone, phoneToAuthEmail } from "@/lib/identity";
import { useSession } from "@/lib/session-provider";

export default function SignIn() {
  const { ctx, client, refresh, notice, setNotice } = useSession();
  const [phone, setPhone] = useState("");
  const [password, setPassword] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const version = appVersionLabel();
  const [error, setError] = useState<string | null>(null);
  const [fieldErrors, setFieldErrors] = useState<{
    phone?: string;
    password?: string;
  }>({});

  if (ctx) return <Redirect href="/" />;

  async function onSubmit() {
    setError(null);
    if (notice) setNotice(null);
    const errs: { phone?: string; password?: string } = {};
    const normalised = phone.trim() ? normalisePhone(phone) : null;
    if (!phone.trim()) errs.phone = "Enter your phone number";
    else if (normalised && !normalised.ok) errs.phone = normalised.message;
    if (!password) errs.password = "Enter your password";
    setFieldErrors(errs);
    if (errs.phone || errs.password || !normalised || !normalised.ok) return; // nothing is sent
    setSubmitting(true);
    try {
      const { error: authError } = await client.auth.signInWithPassword({
        email: phoneToAuthEmail(normalised.e164),
        password,
      });
      if (authError) {
        setError(toUserMessage(authError));
        return;
      }
      await refresh();
    } catch (e) {
      setError(toUserMessage(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Screen testID="sign-in-screen">
      <Text
        accessibilityRole="header"
        style={{ fontSize: 28, fontWeight: "700", color: colors.primary }}
      >
        MouldTrack
      </Text>
      <Text style={{ fontSize: 16, color: colors.muted }}>
        Sign in to your manufacturing unit
      </Text>
      {notice === "password_changed" ? (
        <Text
          testID="sign-in-notice"
          accessibilityRole="alert"
          accessibilityLiveRegion="polite"
          style={{ fontSize: 16, fontWeight: "600", color: colors.text }}
        >
          Password changed. Sign in with your new password.
        </Text>
      ) : null}
      <Field
        label="Phone number"
        testID="phone"
        prefix="+91"
        value={phone}
        onChangeText={setPhone}
        error={fieldErrors.phone}
        autoComplete="tel"
        keyboardType="number-pad"
        inputMode="numeric"
      />
      <PasswordField
        label="Password"
        testID="password"
        value={password}
        onChangeText={setPassword}
        error={fieldErrors.password}
        autoComplete="current-password"
        onSubmitEditing={onSubmit}
      />
      {error ? <ErrorText testID="sign-in-error">{error}</ErrorText> : null}
      <Button
        title="Sign in"
        testID="sign-in-submit"
        onPress={onSubmit}
        disabled={submitting}
        busy={submitting}
      />
      {version ? (
        <Text testID="app-version" style={{ fontSize: 13, color: colors.muted }}>
          {version}
        </Text>
      ) : null}
    </Screen>
  );
}
