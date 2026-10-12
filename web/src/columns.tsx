import type { GridColDef, GridValidRowModel } from "@mui/x-data-grid-pro";
import { money } from "./api";
import { Badge } from "./shared";

// Amounts arrive as exact minor-unit strings. The grid sorts and filters on the
// major-unit number, and always displays the exact string-formatted value.
export function moneyCol<R extends GridValidRowModel>(
  field: string,
  headerName: string,
  minorOf: (r: R) => string,
  placesOf: (r: R) => number,
  extra: Partial<GridColDef<R>> = {},
): GridColDef<R> {
  return {
    field,
    headerName,
    type: "number",
    minWidth: 130,
    flex: 1,
    valueGetter: (_v, r) => Number(minorOf(r)) / 10 ** placesOf(r),
    valueFormatter: (_v, r) => money(minorOf(r), placesOf(r)),
    ...extra,
  };
}

// Plain accounting dates (YYYY-MM-DD) filter as dates but display unchanged.
export function dateCol<R extends GridValidRowModel>(field: string, headerName: string, extra: Partial<GridColDef<R>> = {}): GridColDef<R> {
  return {
    field,
    headerName,
    type: "date",
    minWidth: 120,
    valueGetter: (v: string | null) => (v ? new Date(v + "T00:00:00") : null),
    valueFormatter: (_v, r) => (r as Record<string, string>)[field] ?? "",
    ...extra,
  };
}

export function dateTimeCol<R extends GridValidRowModel>(field: string, headerName: string, extra: Partial<GridColDef<R>> = {}): GridColDef<R> {
  return {
    field,
    headerName,
    type: "dateTime",
    minWidth: 180,
    valueGetter: (v: string | null) => (v ? new Date(v) : null),
    ...extra,
  };
}

export function statusCol<R extends GridValidRowModel>(field: string, headerName: string, options: string[], extra: Partial<GridColDef<R>> = {}): GridColDef<R> {
  return {
    field,
    headerName,
    type: "singleSelect",
    valueOptions: options.map((o) => ({ value: o, label: o.replaceAll("_", " ").toLowerCase() })),
    minWidth: 130,
    renderCell: (p) => (p.value ? <Badge state={String(p.value)} /> : null),
    ...extra,
  };
}
