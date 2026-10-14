// A stand-in for the Claude Messages API, for testing the assistant end to end without a key.
//   node tests/fake-claude.mjs 8787
// Then run the platform with SERK_AI_BASE_URL=http://127.0.0.1:8787 SERK_AI_API_KEY=fake-key.
// It understands three kinds of request: "rent" drafts a rent journal, "VAT" runs the VAT
// report, anything else asks for the company overview; then it summarises the tool result.
import http from 'node:http';
const port=Number(process.argv[2]||8787);
const today=new Date().toISOString().slice(0,10),month=today.slice(0,8)+'01';
http.createServer((req,res)=>{
 let raw='';req.on('data',c=>raw+=c);req.on('end',()=>{
  const reply=o=>{res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify(o));};
  if(req.url!=='/v1/messages'||req.headers['x-api-key']!=='fake-key'){res.writeHead(401);return res.end('{"error":{"message":"bad key"}}');}
  const body=JSON.parse(raw),last=body.messages.at(-1);
  const results=(last.content||[]).filter(b=>b.type==='tool_result');
  if(results.length){
   const r=results[0];
   let text;
   if(r.is_error)text=`I could not do that: ${r.content}`;
   else if(r.content.includes('draft_created')){const d=JSON.parse(r.content);text=`I prepared draft journal **${d.number}** for office rent.\n\n- Debit 6100 Rent: ETB 20,000.00\n- Credit 1010 CBE: ETB 20,000.00\n\nPlease review and submit it; a different authorised person must approve it.`;}
   else text=`Here is what I found:\n\n| Item | Value |\n|---|---|\n| Data | ${r.content.slice(0,80).replace(/\|/g,'/')} |`;
   return reply({content:[{type:'text',text}],stop_reason:'end_turn'});
  }
  const ask=(last.content.find(b=>b.type==='text')?.text||'').toLowerCase();
  // Like a real model, it uses the branch the context names (the first one the user may draft in).
  const branch=(/Branches the user may draft in: ([A-Z0-9_-]+) \(/.exec(body.system||'')||[])[1];
  if(ask.includes('rent'))return reply({content:[{type:'text',text:'I will prepare the entry.'},{type:'tool_use',id:'toolu_rent',name:'draft_journal',input:{branch,accounting_date:today,description:'Office rent',reason:'Rent agreement',lines:[{account_code:'6100',debit:'20000.00'},{account_code:'1010',credit:'20000.00'}]}}],stop_reason:'tool_use'});
  if(ask.includes('vat'))return reply({content:[{type:'tool_use',id:'toolu_vat',name:'vat_report',input:{from:month,to:today}}],stop_reason:'tool_use'});
  return reply({content:[{type:'tool_use',id:'toolu_over',name:'company_overview',input:{}}],stop_reason:'tool_use'});
 });
}).listen(port,'127.0.0.1',()=>console.log('fake Claude on',port));
