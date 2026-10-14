// Browser test of the finance assistant against a demo workspace whose platform points at
// tests/fake-claude.mjs (SERK_AI_BASE_URL=http://127.0.0.1:8787 SERK_AI_API_KEY=fake-key).
//   SERK_BASE_URL=… SERK_DEMO_PASSWORD=… node tests/assistant-browser.mjs
import {chromium,expect} from '../web/node_modules/@playwright/test/index.mjs';
import {mkdirSync} from 'node:fs';
const base=process.env.SERK_BASE_URL||'http://localhost:8080',password=process.env.SERK_DEMO_PASSWORD;
if(!password)throw new Error('SERK_DEMO_PASSWORD required');
const out=process.env.SERK_RESULTS_DIR||'test-results/assistant-browser';mkdirSync(out,{recursive:true});
const browser=await chromium.launch({headless:true,executablePath:process.env.SERK_BROWSER_EXECUTABLE||undefined});
let failures=0;const errors=[];
async function signIn(email){
 const page=await browser.newPage({viewport:{width:1440,height:960}});page.on('pageerror',e=>errors.push(email+': '+e.message));
 await page.goto(base);await page.getByLabel('Workspace',{exact:true}).fill('demo');await page.getByLabel('Email',{exact:true}).fill(email);
 await page.getByLabel('Password',{exact:true}).fill(password);await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await expect(page.getByRole('heading',{name:'Journal workspace'})).toBeVisible({timeout:20000});return page;
}
const step=async(name,page,fn)=>{try{await fn();console.log('PASS',name);}catch(e){failures++;console.log('FAIL',name,e.message.split('\n')[0]);await page.screenshot({path:`${out}/${name.replace(/\W+/g,'-')}.png`}).catch(()=>{});}};

const acc=await signIn('accountant@serk.demo');
await step('accountant asks for a rent entry and reviews the draft',acc,async()=>{
 await acc.getByRole('button',{name:'Open finance assistant'}).click();
 const panel=acc.getByRole('dialog',{name:'Finance assistant'});
 await expect(panel.getByText('Ask about balances')).toBeVisible();
 await panel.getByLabel('Message the assistant').fill('Draft office rent of 20,000 paid today from CBE');
 await panel.getByRole('button',{name:'Send'}).click();
 await expect(panel.getByText(/I prepared draft journal/)).toBeVisible({timeout:30000});
 await expect(panel.getByText(/Looked at: prepared a draft journal/)).toBeVisible();
 await acc.screenshot({path:`${out}/assistant-draft.png`});
 await panel.getByRole('button',{name:'Review'}).click();
 await expect(acc.getByText('Office rent').first()).toBeVisible({timeout:15000});
 await expect(acc.getByText(/Draft/).first()).toBeVisible();
 await acc.screenshot({path:`${out}/assistant-draft-journal.png`});
});
await step('the conversation survives reopening the panel',acc,async()=>{
 await acc.getByRole('button',{name:'Close assistant'}).click();
 await acc.getByRole('button',{name:'Open finance assistant'}).click();
 await expect(acc.getByRole('dialog',{name:'Finance assistant'}).getByText(/I prepared draft journal/)).toBeVisible();
});
const aud=await signIn('auditor@serk.demo');
await step('a read-only auditor cannot make the assistant draft',aud,async()=>{
 await aud.getByRole('button',{name:'Open finance assistant'}).click();
 const panel=aud.getByRole('dialog',{name:'Finance assistant'});
 await panel.getByLabel('Message the assistant').fill('Draft office rent of 20,000');
 await panel.getByRole('button',{name:'Send'}).click();
 await expect(panel.getByText(/could not do that.*permission_denied/)).toBeVisible({timeout:30000});
 await expect(panel.getByText(/refused/)).toBeVisible();
});
await step('VAT question returns a table',aud,async()=>{
 const panel=aud.getByRole('dialog',{name:'Finance assistant'});
 await panel.getByLabel('Message the assistant').fill('What VAT do we owe this month?');
 await panel.getByRole('button',{name:'Send'}).click();
 await expect(panel.locator('.assistant-table table').last()).toBeVisible({timeout:30000});
 await aud.screenshot({path:`${out}/assistant-vat.png`});
});
await browser.close();
if(errors.length){console.log('Browser errors:\n'+errors.join('\n'));failures++;}
console.log(failures?'FAIL':'PASS','assistant browser');process.exitCode=failures?1:0;
