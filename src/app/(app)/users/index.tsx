import { router } from "expo-router";
import { useCallback, useEffect, useRef, useState } from "react";
import { ActivityIndicator, ScrollView, Text, View } from "react-native";
import { NotAllowed } from "@/components/not-allowed";
import { TempPasswordPanel } from "@/components/temp-password-panel";
import {
  Button,
  Chip,
  ConfirmDialog,
  ErrorText,
  Field,
  StatusLabel,
  colors,
} from "@/components/ui";
import { ApiError, newRequestId, userAdminApi } from "@/lib/api";
import { toUserMessage } from "@/lib/errors";
import { formatPhone } from "@/lib/identity";
import { isMember } from "@/lib/session";
import { useSession } from "@/lib/session-provider";
import {
  PAGE_SIZE,
  ROLE_TEXT,
  fetchUsers,
  statusLabel,
  type RoleFilter,
  type StatusFilter,
  type UserRow,
} from "@/lib/users";

const ROLE_FILTERS: { key: RoleFilter; label: string }[] = [
  { key: "all", label: "All" },
  { key: "unit_admin", label: "Unit Admin" },
  { key: "supervisor", label: "Supervisor" },
];
const STATUS_FILTERS: { key: StatusFilter; label: string }[] = [
  { key: "all", label: "All" },
  { key: "active", label: "Active" },
  { key: "inactive", label: "Inactive" },
  { key: "must_change", label: "Must change password" },
];

type Pending = { kind: "toggle" | "reset"; row: UserRow };

export default function Users() {
  const { ctx, client } = useSession();
  const allowed = isMember(ctx) && ctx.role === "unit_admin";
  const myId = isMember(ctx) ? ctx.user.id : "";

  const [search, setSearch] = useState("");
  const [role, setRole] = useState<RoleFilter>("all");
  const [status, setStatus] = useState<StatusFilter>("all");
  const [page, setPage] = useState(0);
  const [reloadKey, setReloadKey] = useState(0);
  const [result, setResult] = useState<{
    key: string;
    error: boolean;
    rows: UserRow[];
    total: number;
  } | null>(null);
  const key = JSON.stringify([search, role, status, page, reloadKey]);
  const state: "loading" | "ready" | "error" =
    !result || result.key !== key
      ? "loading"
      : result.error
        ? "error"
        : "ready";
  const rows = result?.rows ?? [];
  const total = result?.total ?? 0;

  const [pending, setPending] = useState<Pending | null>(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [temp, setTemp] = useState<{ name: string; password: string } | null>(
    null,
  );
  const requestIds = useRef(new Map<string, string>());
  const token = useRef(0);

  useEffect(() => {
    if (!allowed) return;
    const mine = ++token.current;
    fetchUsers(client, { search, role, status, page })
      .then(
        (r) =>
          mine === token.current &&
          setResult({ key, error: false, rows: r.rows, total: r.total }),
      )
      .catch(
        () =>
          mine === token.current &&
          setResult({ key, error: true, rows: [], total: 0 }),
      );
  }, [allowed, client, search, role, status, page, key]);

  const reload = useCallback(() => setReloadKey((k) => k + 1), []);

  if (!isMember(ctx)) return null;
  if (!allowed) return <NotAllowed />;

  const pages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const filtered = search.trim() !== "" || role !== "all" || status !== "all";

  async function confirm() {
    if (!pending) return;
    const { kind, row } = pending;
    const target =
      kind === "toggle"
        ? row.status === "active"
          ? "inactive"
          : "active"
        : "reset";
    const key = `${kind}:${row.user_id}:${target}`;
    const requestId = requestIds.current.get(key) ?? newRequestId();
    requestIds.current.set(key, requestId); // a retry after a network failure reuses it (idempotent)
    setBusy(true);
    setActionError(null);
    try {
      if (kind === "toggle") {
        await userAdminApi.setStatus(
          client,
          row.user_id,
          target as "active" | "inactive",
          requestId,
        );
        reload();
      } else {
        const res = await userAdminApi.resetPassword(
          client,
          row.user_id,
          requestId,
        );
        if (res.temp_password)
          setTemp({ name: row.full_name, password: res.temp_password });
        else
          setActionError(
            res.message ?? "Already done — reset the password if it was lost",
          );
        reload();
      }
      requestIds.current.delete(key);
    } catch (e) {
      setActionError(e instanceof ApiError ? e.message : toUserMessage(e));
    } finally {
      setBusy(false);
      setPending(null);
    }
  }

  return (
    <ScrollView
      testID="users-screen"
      contentContainerStyle={{ alignItems: "center", padding: 24 }}
    >
      <View style={{ width: "100%", maxWidth: 960, gap: 16 }}>
        <View
          style={{
            flexDirection: "row",
            justifyContent: "space-between",
            alignItems: "center",
            flexWrap: "wrap",
            gap: 12,
          }}
        >
          <Text
            accessibilityRole="header"
            style={{ fontSize: 26, fontWeight: "700", color: colors.text }}
          >
            Users
          </Text>
          <View style={{ flexDirection: "row", gap: 12 }}>
            <Button
              title="Home"
              variant="secondary"
              testID="users-home"
              onPress={() => router.replace("/home")}
            />
            <Button
              title="Add user"
              testID="users-add"
              onPress={() => router.push("/users/new")}
            />
          </View>
        </View>

        {temp ? (
          <TempPasswordPanel
            name={temp.name}
            password={temp.password}
            onDone={() => setTemp(null)}
          />
        ) : null}
        {actionError ? (
          <ErrorText testID="users-action-error">{actionError}</ErrorText>
        ) : null}

        <Field
          label="Search users"
          testID="users-search"
          value={search}
          onChangeText={(v) => {
            setSearch(v);
            setPage(0);
          }}
          placeholder="Name, employee ID or phone"
          autoCapitalize="none"
        />
        <View style={{ gap: 8 }}>
          <Text style={{ fontSize: 15, fontWeight: "600", color: colors.text }}>
            Role
          </Text>
          <View style={{ flexDirection: "row", gap: 8, flexWrap: "wrap" }}>
            {ROLE_FILTERS.map((f) => (
              <Chip
                key={f.key}
                testID={`users-filter-role-${f.key}`}
                label={f.label}
                selected={role === f.key}
                onPress={() => {
                  setRole(f.key);
                  setPage(0);
                }}
              />
            ))}
          </View>
          <Text style={{ fontSize: 15, fontWeight: "600", color: colors.text }}>
            Status
          </Text>
          <View style={{ flexDirection: "row", gap: 8, flexWrap: "wrap" }}>
            {STATUS_FILTERS.map((f) => (
              <Chip
                key={f.key}
                testID={`users-filter-status-${f.key}`}
                label={f.label}
                selected={status === f.key}
                onPress={() => {
                  setStatus(f.key);
                  setPage(0);
                }}
              />
            ))}
          </View>
        </View>

        {state === "loading" ? (
          <View
            testID="users-loading"
            accessibilityLabel="Loading users"
            style={{ gap: 12 }}
          >
            <ActivityIndicator color={colors.primary} />
            {[0, 1, 2].map((i) => (
              <View
                key={i}
                style={{
                  height: 72,
                  borderRadius: 8,
                  backgroundColor: "#E6EAEE",
                }}
              />
            ))}
          </View>
        ) : null}

        {state === "error" ? (
          <View style={{ gap: 12 }}>
            <ErrorText testID="users-error">
              {toUserMessage(new TypeError("Failed to fetch"))}
            </ErrorText>
            <Button title="Try again" testID="users-retry" onPress={reload} />
          </View>
        ) : null}

        {state === "ready" && rows.length === 0 ? (
          filtered ? (
            <Text
              testID="users-no-match"
              style={{ fontSize: 16, color: colors.text }}
            >
              No users match
            </Text>
          ) : (
            <Text
              testID="users-empty"
              style={{ fontSize: 16, color: colors.text }}
            >
              No users yet — add your first supervisor
            </Text>
          )
        ) : null}

        {state === "ready"
          ? rows.map((r) => {
              const self = r.user_id === myId;
              return (
                <View
                  key={r.user_id}
                  testID={`user-row-${r.user_id}`}
                  style={{
                    borderWidth: 1,
                    borderColor: colors.border,
                    borderRadius: 8,
                    padding: 12,
                    gap: 8,
                  }}
                >
                  <View
                    style={{
                      flexDirection: "row",
                      flexWrap: "wrap",
                      gap: 16,
                      alignItems: "center",
                    }}
                  >
                    <Text
                      testID={`user-name-${r.user_id}`}
                      style={{
                        fontSize: 17,
                        fontWeight: "700",
                        color: colors.text,
                        minWidth: 160,
                      }}
                    >
                      {r.full_name}
                    </Text>
                    <Text
                      testID={`user-employee-${r.user_id}`}
                      style={{ fontSize: 15, color: colors.text }}
                    >
                      {r.employee_id}
                    </Text>
                    <Text
                      testID={`user-phone-${r.user_id}`}
                      style={{ fontSize: 15, color: colors.text }}
                    >
                      {formatPhone(r.phone_e164)}
                    </Text>
                    <Text
                      testID={`user-role-${r.user_id}`}
                      style={{ fontSize: 15, color: colors.text }}
                    >
                      {ROLE_TEXT[r.role]}
                    </Text>
                    <StatusLabel
                      testID={`user-status-${r.user_id}`}
                      status={statusLabel(r)}
                    />
                  </View>
                  <View
                    style={{ flexDirection: "row", gap: 8, flexWrap: "wrap" }}
                  >
                    <Button
                      title="Edit"
                      variant="secondary"
                      testID={`user-edit-${r.user_id}`}
                      onPress={() => router.push(`/users/${r.user_id}`)}
                    />
                    {self ? null : (
                      <>
                        <Button
                          title={
                            r.status === "active" ? "Deactivate" : "Reactivate"
                          }
                          variant="secondary"
                          testID={`user-toggle-${r.user_id}`}
                          onPress={() => {
                            setActionError(null);
                            setPending({ kind: "toggle", row: r });
                          }}
                        />
                        <Button
                          title="Reset password"
                          variant="secondary"
                          testID={`user-reset-${r.user_id}`}
                          onPress={() => {
                            setActionError(null);
                            setPending({ kind: "reset", row: r });
                          }}
                        />
                      </>
                    )}
                  </View>
                </View>
              );
            })
          : null}

        {state === "ready" && total > 0 ? (
          <View
            style={{
              flexDirection: "row",
              alignItems: "center",
              gap: 12,
              flexWrap: "wrap",
            }}
          >
            <Button
              title="Previous"
              variant="secondary"
              testID="users-prev"
              onPress={() => setPage((p) => Math.max(0, p - 1))}
              disabled={page === 0}
            />
            <Text
              testID="users-page"
              style={{ fontSize: 16, color: colors.text }}
            >
              Page {page + 1} of {pages}
            </Text>
            <Button
              title="Next"
              variant="secondary"
              testID="users-next"
              onPress={() => setPage((p) => p + 1)}
              disabled={page + 1 >= pages}
            />
          </View>
        ) : null}
      </View>

      <ConfirmDialog
        visible={!!pending}
        busy={busy}
        title={
          pending
            ? pending.kind === "reset"
              ? `Reset password for ${pending.row.full_name}?`
              : `${pending.row.status === "active" ? "Deactivate" : "Reactivate"} ${pending.row.full_name}?`
            : ""
        }
        message={
          pending
            ? pending.kind === "reset"
              ? "A new temporary password will be shown once. Their current password stops working."
              : pending.row.status === "active"
                ? "They will lose access at once and cannot sign in until you reactivate them."
                : "They will be able to sign in again with their existing password."
            : ""
        }
        confirmLabel={
          pending
            ? pending.kind === "reset"
              ? "Reset password"
              : pending.row.status === "active"
                ? "Deactivate"
                : "Reactivate"
            : ""
        }
        onConfirm={confirm}
        onCancel={() => setPending(null)}
      />
    </ScrollView>
  );
}
