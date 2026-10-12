package httpapi

import "net/http"

func (s *Server) createItem(w http.ResponseWriter, r *http.Request) { s.masterWrite(w, r, "ITEM") }
func (s *Server) listItems(w http.ResponseWriter, r *http.Request) {
	s.moduleQuery(w, r, "inventory.read", `
 SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) FROM (
 SELECT i.id,i.type,i.name,i.sku,i.active,i.income_account_id,i.expense_account_id,i.asset_account_id,
 i.unit_price::text AS unit_price,i.cost_price::text AS cost_price,coalesce(p.quantity,0)::text AS stock_quantity,
 coalesce(p.value_minor,0)::text AS stock_value_minor,coalesce(p.reserved_quantity,0)::text AS reserved_quantity
 FROM inventory.items i LEFT JOIN finance.positions p ON p.item_id=i.id ORDER BY i.name,i.id LIMIT 200) t`)
}
