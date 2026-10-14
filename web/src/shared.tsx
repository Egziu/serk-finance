import { Layers } from "lucide-react";
export const today = () => new Date().toISOString().slice(0, 10);
export const Icon = ({ size = 19 }: { size?: number }) => (
  <span className="brand-icon" aria-hidden="true">
    <Layers size={size} />
  </span>
);
// The API only names the signed-in user, so other people are shown by a short id.
// Display names of the current company's members, set when reference data loads.
const people = new Map<string, string>();
export function setPeople(list: { id: string; name: string }[] | undefined) {
  people.clear();
  for (const p of list ?? []) people.set(p.id, p.name);
}
export function person(id: string | null | undefined, me: { user_id: string; name: string }) {
  if (!id) return "—";
  return id === me.user_id ? `You (${me.name})` : people.get(id) ?? "User " + id.slice(0, 8);
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
