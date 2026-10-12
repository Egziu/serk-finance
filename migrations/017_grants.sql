GRANT EXECUTE ON FUNCTION ledger.create_account(text, text, text, text, uuid, boolean, boolean, text) TO serk_api;
GRANT EXECUTE ON FUNCTION ledger.update_account(uuid, text, uuid, boolean, boolean, text) TO serk_api;
GRANT EXECUTE ON FUNCTION ledger.create_fiscal_year(text, date, date) TO serk_api;
GRANT EXECUTE ON FUNCTION organization.create_branch(text, text) TO serk_api;
