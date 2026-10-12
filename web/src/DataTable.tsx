import { useState, type ReactNode } from "react";
import {
  DataGridPro,
  Toolbar,
  ColumnsPanelTrigger,
  FilterPanelTrigger,
  ExportCsv,
  ExportPrint,
  QuickFilter,
  QuickFilterControl,
  QuickFilterClear,
  useGridApiContext,
  useGridSelector,
  gridDensitySelector,
  type GridColDef,
  type GridDensity,
  type GridFilterModel,
  type GridInitialState,
  type GridRowIdGetter,
  type GridRowParams,
  type GridValidRowModel,
} from "@mui/x-data-grid-pro";
import { Badge, Button, IconButton, InputAdornment, ListItemIcon, Menu, MenuItem, TextField } from "@mui/material";
import { nonce } from "./csp";
import { Check, Columns3, Download, FileSpreadsheet, ListFilter, Plus, Printer, Rows3, Search, X } from "lucide-react";

declare module "@mui/x-data-grid-pro" {
  interface ToolbarPropsOverrides {
    onAdd?: () => void;
    addLabel?: string;
    fileName?: string;
  }
}

const densities: [GridDensity, string][] = [
  ["compact", "Compact"],
  ["standard", "Standard"],
  ["comfortable", "Comfortable"],
];

function DensityMenu() {
  const apiRef = useGridApiContext();
  const density = useGridSelector(apiRef, gridDensitySelector);
  const [anchor, setAnchor] = useState<HTMLElement | null>(null);
  return (
    <>
      <Button size="small" startIcon={<Rows3 size={16} />} onClick={(e) => setAnchor(e.currentTarget)} aria-haspopup="menu">
        Density
      </Button>
      <Menu anchorEl={anchor} open={!!anchor} onClose={() => setAnchor(null)}>
        {densities.map(([value, label]) => (
          <MenuItem
            key={value}
            selected={density === value}
            onClick={() => {
              apiRef.current?.setDensity(value);
              setAnchor(null);
            }}
          >
            <ListItemIcon>{density === value && <Check size={16} />}</ListItemIcon>
            {label}
          </MenuItem>
        ))}
      </Menu>
    </>
  );
}

function ExportMenu({ fileName }: { fileName?: string }) {
  const [anchor, setAnchor] = useState<HTMLElement | null>(null);
  const close = () => setAnchor(null);
  return (
    <>
      <Button size="small" startIcon={<Download size={16} />} onClick={(e) => setAnchor(e.currentTarget)} aria-haspopup="menu">
        Export
      </Button>
      <Menu anchorEl={anchor} open={!!anchor} onClose={close}>
        <ExportCsv render={<MenuItem />} options={{ fileName, utf8WithBom: true }} onClick={close}>
          <ListItemIcon>
            <FileSpreadsheet size={16} />
          </ListItemIcon>
          Download as CSV
        </ExportCsv>
        <ExportPrint render={<MenuItem />} onClick={close}>
          <ListItemIcon>
            <Printer size={16} />
          </ListItemIcon>
          Print
        </ExportPrint>
      </Menu>
    </>
  );
}

function GridToolbar({ onAdd, addLabel, fileName }: { onAdd?: () => void; addLabel?: string; fileName?: string }) {
  return (
    <Toolbar className="grid-toolbar">
      <QuickFilter debounceMs={250}>
        <QuickFilterControl
          render={({ ref, ...other }) => (
            <TextField
              {...other}
              inputRef={ref}
              size="small"
              placeholder="Search…"
              slotProps={{
                ...other.slotProps,
                htmlInput: { ...other.slotProps?.htmlInput, "aria-label": "Search table" },
                input: {
                  startAdornment: (
                    <InputAdornment position="start">
                      <Search size={16} />
                    </InputAdornment>
                  ),
                  endAdornment: other.value ? (
                    <InputAdornment position="end">
                      <QuickFilterClear render={<IconButton size="small" aria-label="Clear search" />}>
                        <X size={14} />
                      </QuickFilterClear>
                    </InputAdornment>
                  ) : null,
                  ...other.slotProps?.input,
                },
              }}
            />
          )}
        />
      </QuickFilter>
      <span className="grid-toolbar-spacer" />
      {onAdd && (
        <Button size="small" startIcon={<Plus size={16} />} onClick={onAdd}>
          {addLabel ?? "Add record"}
        </Button>
      )}
      <ColumnsPanelTrigger render={<Button size="small" startIcon={<Columns3 size={16} />} />}>Columns</ColumnsPanelTrigger>
      <FilterPanelTrigger
        render={(props, state) => (
          <Button
            {...props}
            size="small"
            startIcon={
              <Badge badgeContent={state.filterCount} color="primary" variant="dot">
                <ListFilter size={16} />
              </Badge>
            }
          >
            Filters
          </Button>
        )}
      />
      <DensityMenu />
      <ExportMenu fileName={fileName} />
    </Toolbar>
  );
}

type Props<R extends GridValidRowModel> = {
  label: string;
  title?: string;
  description?: string;
  rows: R[];
  columns: GridColDef<R>[];
  loading?: boolean;
  getRowId?: GridRowIdGetter<R>;
  initialState?: GridInitialState;
  filterModel?: GridFilterModel;
  onFilterModelChange?: (m: GridFilterModel) => void;
  onAdd?: () => void;
  addLabel?: string;
  fileName?: string;
  height?: number;
  autoHeight?: boolean;
  pageSize?: number;
  detailPanel?: (row: R) => ReactNode;
  footerNote?: ReactNode;
};

// One grid for every record list: search, column menu (sort, pin, filter, hide, manage),
// multi-condition filters, resizable/reorderable columns, density, CSV/print export and paging.
export function DataTable<R extends GridValidRowModel>({
  label,
  title,
  description,
  rows,
  columns,
  loading,
  getRowId,
  initialState,
  filterModel,
  onFilterModelChange,
  onAdd,
  addLabel,
  fileName,
  height = 620,
  autoHeight,
  pageSize = 25,
  detailPanel,
  footerNote,
}: Props<R>) {
  return (
    <section className="panel data-table">
      {(title || description) && (
        <div style={{ padding: '16px 20px', borderBottom: '1px solid var(--divider)', background: 'var(--surface-50)' }}>
          {title && <h2 style={{ margin: 0, fontSize: 16, fontWeight: 600 }}>{title}</h2>}
          {description && <p style={{ margin: '4px 0 0 0', color: 'var(--text-secondary)' }}>{description}</p>}
        </div>
      )}
      <div style={autoHeight ? undefined : { height }}>
        <DataGridPro<R>
          label={label}
          nonce={nonce}
          rows={rows}
          columns={columns}
          loading={loading}
          getRowId={getRowId}
          autoHeight={autoHeight}
          showToolbar
          slots={{ toolbar: GridToolbar }}
          slotProps={{
            toolbar: { onAdd, addLabel, fileName },
            loadingOverlay: { variant: "linear-progress", noRowsVariant: "skeleton" },
          }}
          pagination
          pageSizeOptions={[10, 25, 50, 100]}
          initialState={{ pagination: { paginationModel: { pageSize } }, ...initialState }}
          {...(filterModel ? { filterModel, onFilterModelChange } : {})}
          disableRowSelectionOnClick
          {...(detailPanel
            ? {
                getDetailPanelContent: (p: GridRowParams<R>) => detailPanel(p.row),
                getDetailPanelHeight: () => "auto" as const,
              }
            : {})}
          sx={{
            border: 0,
            fontSize: 13,
            "--DataGrid-containerBackground": "#fbfcfb",
            "& .MuiDataGrid-columnHeaderTitle": { fontSize: 11, fontWeight: 500, color: "#6e7d76" },
            "& .MuiDataGrid-cell:focus, & .MuiDataGrid-columnHeader:focus": { outline: "none" },
            "& .MuiDataGrid-cell:focus-within": { outline: "2px solid #16645333", outlineOffset: -2 },
          }}
        />
      </div>
      {footerNote && <div className="report-note">{footerNote}</div>}
    </section>
  );
}
