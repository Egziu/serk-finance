import { ControlledFinance, type FinanceProps } from "../ControlledFinance";
export function SalesPage(props:FinanceProps){return <ControlledFinance {...props} kind="INVOICE"/>;}
export function PurchasesPage(props:FinanceProps){return <ControlledFinance {...props} kind="BILL"/>;}
