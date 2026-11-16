import { NotAllowed } from "@/components/not-allowed";
import { UserForm } from "@/components/user-form";
import { isMember } from "@/lib/session";
import { useSession } from "@/lib/session-provider";

export default function NewUser() {
  const { ctx } = useSession();
  if (!isMember(ctx)) return null;
  if (ctx.role !== "unit_admin") return <NotAllowed />;
  return <UserForm />;
}
