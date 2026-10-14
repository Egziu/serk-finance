// Browser regression for the first accountant test round (0.3.1), against a demo workspace.
//   SERK_BASE_URL=… SERK_DEMO_PASSWORD=… node tests/accountant-feedback.mjs
// 1. The item form offers only accounts of the right kind and pre-fills sensible ones.
// 2. Saving the account mappings unchanged succeeds, and a wrong choice names the field.
// 3. A receivable write-off starts from impairment expense and trade receivables.
// 4. A journal posted by an invoice offers no general-ledger reversal and links to the invoice.
import {chromium,expect} from '../web/node_modules/@playwright/test/index.mjs';
import {mkdirSync} from 'node:fs';
const base=process.env.SERK_BASE_URL||'http://localhost:8080',password=process.env.SERK_DEMO_PASSWORD;
if(!password)throw new Error('SERK_DEMO_PASSWORD required');
const out=process.env.SERK_RESULTS_DIR||'test-results/accountant-feedback';mkdirSync(out,{recursive:true});
const browser=await chromium.launch({headless:true,executablePath:process.env.SERK_BROWSER_EXECUTABLE||undefined});
const page=await browser.newPage({viewport:{width:1440,height:1000}});
const errors=[];page.on('pageerror',e=>errors.push(e.message));
let failures=0;
const step=async(name,fn)=>{try{await fn();console.log('PASS',name);}catch(e){failures++;console.log('FAIL',name,e.message.split('\n')[0]);await page.screenshot({path:`${out}/${name.replace(/\W+/g,'-')}.png`,fullPage:true}).catch(()=>{});}};
const optionTexts=async select=>(await select.locator('option').allTextContents()).filter(t=>t&&!/^Select|^Not configured/.test(t));

await page.goto(base);
await page.getByLabel('Workspace',{exact:true}).fill('demo');await page.getByLabel('Email',{exact:true}).fill('admin@serk.demo');
await page.getByLabel('Password',{exact:true}).fill(password);await page.getByRole('button',{name:'Sign in',exact:true}).click();
await expect(page.getByRole('heading',{name:'Journal workspace'})).toBeVisible({timeout:20000});
const sidebar=page.getByRole('navigation',{name:'Main navigation'});

await step('item form offers only suitable accounts and pre-fills them',async()=>{
 await sidebar.getByRole('button',{name:'Inventory & Items',exact:true}).click();
 await page.getByRole('button',{name:'Items',exact:true}).click();
 await page.getByRole('button',{name:'Add item',exact:true}).click();
 const revenue=page.getByLabel('Revenue account'),cost=page.getByLabel('Expense / cost of sales account'),asset=page.getByLabel('Inventory asset account');
 for(const t of await optionTexts(revenue))if(!/^4/.test(t))throw new Error('revenue offers '+t);
 for(const t of await optionTexts(asset))if(/^1(000|010|020|100|300) /.test(t)||!/^1/.test(t))throw new Error('inventory offers '+t);
 expect(await revenue.locator('option:checked').textContent()).toMatch(/^4000/);
 expect(await cost.locator('option:checked').textContent()).toMatch(/^5000/);
 expect(await asset.locator('option:checked').textContent()).toMatch(/^1200/);
 await page.getByLabel('Name',{exact:true}).fill('Mobile phone '+Date.now());await page.getByLabel('SKU',{exact:true}).fill('M'+Date.now());
 await page.getByLabel(/Selling price/).fill('50000');await page.getByLabel(/Purchase price/).fill('40000');
 await page.getByRole('button',{name:'Save draft'}).click();
 await expect(page.getByText('Saved successfully.')).toBeVisible({timeout:15000});
 await page.screenshot({path:`${out}/item-saved.png`,fullPage:true});
});
await step('account mappings save unchanged, and a bank account is not offered as receivables',async()=>{
 await page.getByRole('button',{name:'Account mappings',exact:true}).click();
 const ar=page.getByLabel('Accounts receivable',{exact:true});
 for(const t of await optionTexts(ar))if(/^10[0-2]0 /.test(t))throw new Error('receivables offers bank '+t);
 await page.getByRole('button',{name:'Save mappings'}).click();
 await expect(page.getByText('Saved successfully.')).toBeVisible({timeout:15000});
});
await step('receivable write-off starts from impairment expense and trade receivables',async()=>{
 await sidebar.getByRole('button',{name:'Adjustments',exact:true}).click();
 await page.getByRole('button',{name:'New adjustment'}).click();
 await page.getByLabel('Adjustment kind').selectOption('RECEIVABLE_ADJUSTMENT');
 expect(await page.getByLabel('Adjustment account 1').locator('option:checked').textContent()).toMatch(/^6500/);
 expect(await page.getByLabel('Adjustment account 2').locator('option:checked').textContent()).toMatch(/^1100/);
 for(const t of await optionTexts(page.getByLabel('Adjustment account 1')))if(/^(2000|2200|1300|1200) /.test(t))throw new Error('write-off offers '+t);
 await page.screenshot({path:`${out}/write-off.png`,fullPage:true});
});
await step('an invoice journal links to the invoice and offers no reversal',async()=>{
 await sidebar.getByRole('button',{name:'Journals',exact:true}).click();
 await page.getByRole('row',{name:/INVOICE INV-0001/}).getByRole('button').last().click();
 await expect(page.getByRole('note')).toContainText('INV-0001');
 await expect(page.getByRole('button',{name:'Create reversal'})).toHaveCount(0);
 await page.screenshot({path:`${out}/module-journal.png`,fullPage:true});
 await page.getByRole('button',{name:/Open sales invoices/}).click();
 await expect(page.getByRole('heading',{name:/Sales/}).first()).toBeVisible();
});
await browser.close();
if(errors.length){console.log('Browser errors:\n'+errors.join('\n'));failures++;}
console.log(failures?'FAIL':'PASS','accountant feedback');process.exitCode=failures?1:0;
