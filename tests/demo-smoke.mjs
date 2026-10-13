// Smoke test of a deployed accountant test workspace (local or Railway).
//   SERK_BASE_URL=https://… SERK_DEMO_PASSWORD=… node tests/demo-smoke.mjs
// Signs in as each demo role, checks the navigation matches the role's permissions, opens the
// main screens, switches a module off and on again as the administrator, and fails on any
// browser error. Read-only apart from that reversible module switch.
import {chromium,expect} from '../web/node_modules/@playwright/test/index.mjs';
import {mkdirSync} from 'node:fs';
const base=process.env.SERK_BASE_URL||'http://localhost:8080',password=process.env.SERK_DEMO_PASSWORD;
if(!password)throw new Error('SERK_DEMO_PASSWORD required');
const out=process.env.SERK_RESULTS_DIR||'test-results/demo-smoke';mkdirSync(out,{recursive:true});
const browser=await chromium.launch({headless:true,executablePath:process.env.SERK_BROWSER_EXECUTABLE||undefined});
const expectNav={
 'admin@serk.demo':{has:['Sales & AR','Payroll & HR','Adjustments','Year-end & reopen','Users & roles','Modules & features'],not:[]},
 'accountant@serk.demo':{has:['Sales & AR','Purchases & AP','Inventory & Items','Adjustments','Taxes & Rates'],not:['Payroll & HR','Users & roles','Modules & features','Year-end & reopen']},
 'payroll@serk.demo':{has:['Payroll & HR','Adjustments'],not:['Sales & AR','Purchases & AP','Users & roles']},
 'sales@serk.demo':{has:['Sales & AR','Inventory & Items'],not:['Payroll & HR','Purchases & AP','Users & roles']},
 'auditor@serk.demo':{has:['Audit history','Sales & AR','Payroll & HR'],not:['Adjustments','Users & roles','Modules & features']},
 'manager@serk.demo':{has:['Year-end & reopen','Adjustments'],not:['Users & roles','Modules & features']},
};
const errors=[];let failures=0;
for(const [email,nav] of Object.entries(expectNav)){
 const page=await browser.newPage({viewport:{width:1440,height:1000}});
 page.on('pageerror',e=>errors.push(email+': '+e.message));
 try{
  await page.goto(base);await page.getByLabel('Workspace',{exact:true}).fill('demo');await page.getByLabel('Email',{exact:true}).fill(email);
  await page.getByLabel('Password',{exact:true}).fill(password);await page.getByRole('button',{name:'Sign in',exact:true}).click();
  await expect(page.getByRole('heading',{name:'Journal workspace'})).toBeVisible({timeout:20000});
  const sidebar=page.getByRole('navigation',{name:'Main navigation'});
  for(const label of nav.has)await expect(sidebar.getByRole('button',{name:label,exact:true})).toBeVisible();
  for(const label of nav.not)await expect(sidebar.getByRole('button',{name:label,exact:true})).toHaveCount(0);
  for(const [label,heading] of [['Trial balance','Trial balance'],['Financial statements',/Balance Sheet|Financial statements/],['Fiscal periods','Fiscal periods']])
   {await sidebar.getByRole('button',{name:label,exact:true}).click();await expect(page.getByRole('heading',{level:1,name:heading}).first()).toBeVisible({timeout:20000});}
  await page.screenshot({path:`${out}/${email.split('@')[0]}.png`,fullPage:true});
  if(email==='admin@serk.demo'){
   await sidebar.getByRole('button',{name:'Modules & features',exact:true}).click();
   await page.getByRole('button',{name:'Turn off Payroll',exact:true}).click();await page.getByLabel('Change reason',{exact:true}).fill('Smoke test: switch off');
   await page.getByRole('button',{name:'Confirm',exact:true}).click();await expect(sidebar.getByRole('button',{name:'Payroll & HR',exact:true})).toHaveCount(0);
   await page.screenshot({path:`${out}/admin-modules.png`,fullPage:true});
   await page.getByRole('button',{name:'Turn on Payroll',exact:true}).click();await page.getByLabel('Change reason',{exact:true}).fill('Smoke test: switch back on');
   await page.getByRole('button',{name:'Confirm',exact:true}).click();await expect(sidebar.getByRole('button',{name:'Payroll & HR',exact:true})).toBeVisible();
  }
  console.log('PASS',email);
 }catch(e){failures++;console.log('FAIL',email,e.message.split('\n')[0]);await page.screenshot({path:`${out}/${email.split('@')[0]}-fail.png`,fullPage:true}).catch(()=>{});}
 await page.close();
}
await browser.close();
if(errors.length){console.log('Browser errors:\n'+errors.join('\n'));failures++;}
console.log(failures?'FAIL':'PASS','demo smoke');process.exitCode=failures?1:0;
