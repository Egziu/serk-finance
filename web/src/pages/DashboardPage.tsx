import {useEffect,useState} from "react";
import {api,money} from "../api";
import {today} from "../shared";
import type {Trial} from "../types";
type Props={company:string;currencyPlaces:number;currencyCode?:string;onAccount?:(id:string)=>void};
type Data={as_of:string;from:string;receivable_configured:boolean;payable_configured:boolean;metrics:Record<string,string>;cashflow:{month:string;income:string;expense:string}[]};
export function DashboardPage({company,currencyPlaces,currencyCode="ETB",onAccount}:Props){
 const[data,setData]=useState<Data|null>(null),[trial,setTrial]=useState<Trial|null>(null),[error,setError]=useState(""),[asof,setAsof]=useState(today());
 useEffect(()=>{let active=true;setError("");void Promise.all([api<Data>("/dashboard/metrics?as_of="+asof,company),api<Trial>("/reports/trial-balance?as_of="+asof,company)]).then(([d,t])=>{if(active){setData(d);setTrial(t)}}).catch(e=>{if(active)setError(e.message)});return()=>{active=false}},[company,asof]);
 const format=(n:string)=>currencyCode+" "+money(n,currencyPlaces);
 return <section><div className="page-heading"><div><div className="eyebrow">FINANCE OVERVIEW</div><h1>Dashboard</h1><p>Posted ledger balances and performance.</p></div><label>As of<input type="date" value={asof} onChange={e=>setAsof(e.target.value)}/></label></div>{error&&<div className="error" role="alert">{error}</div>}
 {data&&<><p>Performance period: {data.from} to {data.as_of}</p><div className="finance-grid">{[["Revenue","total_revenue"],["Expenses","total_expenses"],["Cash and bank","cash_balance"],["Accounts receivable","accounts_receivable"],["Accounts payable","accounts_payable"]].map(([label,key])=><article className="summary-card" key={key}><h3>{label}</h3><strong>{key==="accounts_receivable"&&!data.receivable_configured||key==="accounts_payable"&&!data.payable_configured?"Configure account mapping":format(data.metrics[key])}</strong></article>)}</div><h2>Monthly revenue and expense</h2><div className="finance-table"><table><thead><tr><th>Month</th><th>Revenue</th><th>Expense</th><th>Net</th></tr></thead><tbody>{data.cashflow.map(x=><tr key={x.month}><td>{x.month}</td><td>{format(x.income)}</td><td>{format(x.expense)}</td><td>{format((BigInt(x.income)-BigInt(x.expense)).toString())}</td></tr>)}</tbody></table></div></>}
 {trial&&<><h2>Account balances</h2><div className="finance-table"><table><thead><tr><th>Account</th><th>Debit</th><th>Credit</th><th>Net debit</th></tr></thead><tbody>{trial.rows.map(a=><tr key={a.account_id}><td><button onClick={()=>onAccount?.(a.account_id)}>{a.code} — {a.name}</button></td><td>{format(a.debit_minor)}</td><td>{format(a.credit_minor)}</td><td>{format(a.net_debit_minor)}</td></tr>)}</tbody></table></div></>}
 </section>;
}
