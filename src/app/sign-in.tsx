import { Redirect } from 'expo-router';
import { useState } from 'react';
import { Pressable, Text } from 'react-native';
import { Button, ErrorText, Field, Screen, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { useSession } from '@/lib/session-provider';

export default function SignIn() {
  const { ctx, client, refresh } = useSession();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (ctx) return <Redirect href="/" />;

  async function onSubmit() {
    setSubmitting(true);
    setError(null);
    try {
      const { error: authError } = await client.auth.signInWithPassword({ email: email.trim(), password });
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
      <Text accessibilityRole="header" style={{ fontSize: 28, fontWeight: '700', color: colors.primary }}>
        MouldTrack
      </Text>
      <Text style={{ fontSize: 16, color: colors.muted }}>Sign in to your manufacturing unit</Text>
      <Field
        label="Email"
        testID="email"
        value={email}
        onChangeText={setEmail}
        autoCapitalize="none"
        autoComplete="email"
        keyboardType="email-address"
        inputMode="email"
      />
      <Field
        label="Password"
        testID="password"
        value={password}
        onChangeText={setPassword}
        secureTextEntry={!showPassword}
        autoComplete="current-password"
        onSubmitEditing={onSubmit}
      />
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={showPassword ? 'Hide password' : 'Show password'}
        onPress={() => setShowPassword((s) => !s)}
        style={{ minHeight: 48, justifyContent: 'center', alignSelf: 'flex-start' }}
      >
        <Text style={{ color: colors.primary, fontSize: 15 }}>{showPassword ? 'Hide password' : 'Show password'}</Text>
      </Pressable>
      {error ? <ErrorText testID="sign-in-error">{error}</ErrorText> : null}
      <Button
        title="Sign in"
        testID="sign-in-submit"
        onPress={onSubmit}
        disabled={submitting || !email || !password}
        busy={submitting}
      />
    </Screen>
  );
}
