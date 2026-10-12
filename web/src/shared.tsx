import { Layers } from "lucide-react";
export const today = () => new Date().toISOString().slice(0, 10);
export const Icon = ({ size = 19 }: { size?: number }) => (
  <span className="brand-icon" aria-hidden="true">
    <Layers size={size} />
  </span>
);
// The API only names the signed-in user, so other people are shown by a short id.
export function person(id: string | null | undefined, me: { user_id: string; name: string }) {
  if (!id) return "—";
  return id === me.user_id ? `You (${me.name})` : "User " + id.slice(0, 8);
}
export const when = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleString() : "—");
export function Badge({ state }: { state: string }) {
  return (
    <span className={"badge " + state.toLowerCase()}>
      <i />
      {state.replaceAll("_", " ").toLowerCase()}
    </span>
  );
}
