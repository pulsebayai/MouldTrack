import { router } from "expo-router";
import { useEffect, useRef, useState } from "react";
import { ActivityIndicator, ScrollView, Text, View } from "react-native";
import { TempPasswordPanel } from "@/components/temp-password-panel";
import { Button, Chip, ErrorText, Field, colors } from "@/components/ui";
import {
  ApiError,
  newRequestId,
  userAdminApi,
  type UpdateInput,
} from "@/lib/api";
import { toUserMessage } from "@/lib/errors";
import { normalisePhone } from "@/lib/identity";
import { useSession } from "@/lib/session-provider";
import { fetchUser, ROLE_TEXT, type UserRow } from "@/lib/users";

type FormRole = "unit_admin" | "supervisor";
type Errors = Partial<
  Record<"full_name" | "employee_id" | "phone" | "role" | "form", string>
>;

const NAME_ERROR = "Enter a name of 1 to 80 characters";
const EMP_ERROR = "Employee ID: 1 to 30 letters, digits, - _ or /";

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <ScrollView contentContainerStyle={{ alignItems: "center", padding: 24 }}>
      <View style={{ width: "100%", maxWidth: 480, gap: 16 }}>{children}</View>
    </ScrollView>
  );
}

export function UserForm({ userId }: { userId?: string }) {
  const { client } = useSession();
  const editing = !!userId;
  const [loaded, setLoaded] = useState<UserRow | null>(null);
  const [outcome, setOutcome] = useState<{
    key: string;
    state: "ready" | "error" | "missing";
  } | null>(null);
  const [name, setName] = useState("");
  const [emp, setEmp] = useState("");
  const [phone, setPhone] = useState("");
  const [role, setRole] = useState<FormRole>("supervisor");
  const [errors, setErrors] = useState<Errors>({});
  const [busy, setBusy] = useState(false);
  const [created, setCreated] = useState<{
    name: string;
    password: string;
  } | null>(null);
  const requestId = useRef(newRequestId());
  const [reloadKey, setReloadKey] = useState(0);

  const loadKey = `${userId}:${reloadKey}`;
  const load: "loading" | "ready" | "error" | "missing" = !editing
    ? "ready"
    : !outcome || outcome.key !== loadKey
      ? "loading"
      : outcome.state;

  useEffect(() => {
    if (!userId) return;
    let live = true;
    fetchUser(client, userId)
      .then((row) => {
        if (!live) return;
        if (!row) return setOutcome({ key: loadKey, state: "missing" });
        setLoaded(row);
        setName(row.full_name);
        setEmp(row.employee_id);
        setPhone(row.phone_e164.slice(3));
        setRole(row.role === "unit_admin" ? "unit_admin" : "supervisor");
        setOutcome({ key: loadKey, state: "ready" });
      })
      .catch(() => live && setOutcome({ key: loadKey, state: "error" }));
    return () => {
      live = false;
    };
  }, [client, userId, loadKey]);

  if (created) {
    return (
      <Shell>
        <TempPasswordPanel
          name={created.name}
          password={created.password}
          onDone={() => {
            setCreated(null);
            router.replace("/users");
          }}
        />
      </Shell>
    );
  }
  if (load === "loading") {
    return (
      <Shell>
        <ActivityIndicator
          testID="user-form-loading"
          color={colors.primary}
          accessibilityLabel="Loading user"
        />
      </Shell>
    );
  }
  if (load === "error") {
    return (
      <Shell>
        <ErrorText testID="user-form-load-error">
          {toUserMessage(new TypeError("Failed to fetch"))}
        </ErrorText>
        <Button
          title="Try again"
          testID="user-form-retry"
          onPress={() => setReloadKey((k) => k + 1)}
        />
      </Shell>
    );
  }
  if (load === "missing") {
    return (
      <Shell>
        <Text
          testID="user-not-found"
          accessibilityRole="header"
          style={{ fontSize: 20, fontWeight: "700", color: colors.text }}
        >
          User not found
        </Text>
        <Button
          title="Back to users"
          variant="secondary"
          testID="user-cancel"
          onPress={() => router.replace("/users")}
        />
      </Shell>
    );
  }

  async function onSave() {
    const e: Errors = {};
    const trimmedName = name.trim();
    const trimmedEmp = emp.trim();
    if (trimmedName.length < 1 || trimmedName.length > 80)
      e.full_name = NAME_ERROR;
    if (!/^[A-Za-z0-9_/-]{1,30}$/.test(trimmedEmp)) e.employee_id = EMP_ERROR;
    const p = normalisePhone(phone);
    if (!p.ok) e.phone = p.message;
    if (Object.keys(e).length || !p.ok) {
      setErrors(e);
      return;
    }

    let diff: UpdateInput = {};
    if (editing && loaded) {
      if (trimmedName !== loaded.full_name) diff.full_name = trimmedName;
      if (trimmedEmp !== loaded.employee_id) diff.employee_id = trimmedEmp;
      if (p.e164 !== loaded.phone_e164) diff.phone = p.e164;
      if (role !== loaded.role) diff.role = role;
      if (Object.keys(diff).length === 0) {
        setErrors({ form: "No changes to save" });
        return;
      }
    }

    setBusy(true);
    setErrors({});
    try {
      if (editing) {
        await userAdminApi.update(client, userId!, diff, requestId.current);
        router.replace("/users");
      } else {
        const res = await userAdminApi.create(
          client,
          {
            full_name: trimmedName,
            employee_id: trimmedEmp,
            phone: p.e164,
            role,
          },
          requestId.current,
        );
        if (res.already || !res.temp_password) {
          setErrors({
            form:
              res.message ?? "Already done — reset the password if it was lost",
          });
        } else {
          requestId.current = newRequestId();
          setCreated({ name: trimmedName, password: res.temp_password });
        }
      }
    } catch (err) {
      if (
        err instanceof ApiError &&
        err.field &&
        ["full_name", "employee_id", "phone", "role"].includes(err.field)
      ) {
        setErrors({ [err.field]: err.message } as Errors);
      } else {
        setErrors({
          form: err instanceof ApiError ? err.message : toUserMessage(err),
        });
      }
    } finally {
      setBusy(false);
    }
  }

  return (
    <Shell>
      <View testID="user-form" style={{ gap: 16 }}>
        <Text
          accessibilityRole="header"
          style={{ fontSize: 24, fontWeight: "700", color: colors.text }}
        >
          {editing ? "Edit user" : "Add user"}
        </Text>
        <Field
          label="Full name"
          testID="full-name"
          value={name}
          onChangeText={setName}
          error={errors.full_name}
          autoComplete="off"
        />
        <Field
          label="Employee ID"
          testID="employee-id"
          value={emp}
          onChangeText={setEmp}
          error={errors.employee_id}
          autoCapitalize="characters"
          autoComplete="off"
        />
        <Field
          label="Phone number"
          testID="phone"
          prefix="+91"
          value={phone}
          onChangeText={setPhone}
          error={errors.phone}
          keyboardType="number-pad"
          inputMode="numeric"
          autoComplete="off"
        />
        <View style={{ gap: 6 }}>
          <Text style={{ fontSize: 15, fontWeight: "600", color: colors.text }}>
            Role
          </Text>
          <View style={{ flexDirection: "row", gap: 12, flexWrap: "wrap" }}>
            {(["supervisor", "unit_admin"] as FormRole[]).map((r) => (
              <Chip
                key={r}
                testID={`role-${r}`}
                label={ROLE_TEXT[r]}
                selected={role === r}
                onPress={() => setRole(r)}
              />
            ))}
          </View>
          {errors.role ? (
            <ErrorText testID="role-error">{errors.role}</ErrorText>
          ) : null}
        </View>
        {errors.form ? (
          <ErrorText testID="user-form-error">{errors.form}</ErrorText>
        ) : null}
        <Button
          title={editing ? "Save changes" : "Create user"}
          testID="user-save"
          onPress={onSave}
          disabled={busy}
          busy={busy}
        />
        <Button
          title="Cancel"
          variant="secondary"
          testID="user-cancel"
          onPress={() => router.replace("/users")}
          disabled={busy}
        />
      </View>
    </Shell>
  );
}
