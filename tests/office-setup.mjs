// Browser test of an office installation's first run: the setup wizard creates the company and
// administrator, then the administrator signs in. Run against a fresh `serk-server run`.
//   SERK_BASE_URL=http://localhost:8080 node tests/office-setup.mjs
import {chromium,expect} from '../web/node_modules/@playwright/test/index.mjs';
import {mkdirSync} from 'node:fs';
const base=process.env.SERK_BASE_URL||'http://localhost:8080';
const out=process.env.SERK_RESULTS_DIR||'test-results/office-setup';mkdirSync(out,{recursive:true});
const password='Office-Admin-Password-2026';
const browser=await chromium.launch({headless:true,executablePath:process.env.SERK_BROWSER_EXECUTABLE||undefined});
const page=await browser.newPage({viewport:{width:1280,height:1000}});
const errors=[];page.on('pageerror',e=>errors.push(e.message));
let failures=0;
const step=async(name,fn)=>{try{await fn();console.log('PASS',name);}catch(e){failures++;console.log('FAIL',name,e.message.split('\n')[0]);await page.screenshot({path:`${out}/${name.replace(/\W+/g,'-')}.png`,fullPage:true}).catch(()=>{});}};

await step('the first visit opens the setup wizard with Hamle 1 suggested',async()=>{
 await page.goto(base);
 await expect(page).toHaveURL(/\/setup/);
 await expect(page.getByRole('heading',{name:'Set up your company'})).toBeVisible();
 const start=await page.getByLabel('First day of the fiscal year').inputValue();
 if(!/^\d{4}-07-0[78]$/.test(start))throw new Error('suggested start '+start);
});
await step('mismatched passwords are caught before submitting',async()=>{
 await page.getByLabel('Company name').fill('Abay Trading PLC');
 await page.getByLabel('Workspace (sign-in name)').fill('abay');
 await page.getByLabel('Branches').fill('HQ, ADDIS');
 await page.getByLabel('Full name').fill('Almaz Tesfaye');
 await page.getByLabel('Email').fill('almaz@abay.example');
 await page.getByLabel('Password',{exact:true}).fill(password);
 await page.getByLabel('Confirm password').fill(password+'x');
 await page.getByRole('button',{name:'Create my company'}).click();
 await expect(page.getByRole('alert')).toContainText('do not match');
});
await step('setup creates the company and the practice workspace',async()=>{
 await page.getByLabel('Confirm password').fill(password);
 await page.getByLabel(/practice workspace/).check();
 await page.screenshot({path:`${out}/setup-form.png`,fullPage:true});
 await page.getByRole('button',{name:'Create my company'}).click();
 await expect(page.getByRole('heading',{name:'Your company is ready'})).toBeVisible({timeout:120000});
 const practice=await page.locator('#practice-password').textContent();
 if(!/^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){3}$/.test(practice||'')||practice===password)throw new Error('practice password '+practice);
 globalThis.practicePassword=practice;
 await page.screenshot({path:`${out}/setup-done.png`,fullPage:true});
});
await step('the administrator signs in and finds the Ethiopian year and chart',async()=>{
 await page.getByRole('button',{name:'Go to sign in'}).click();
 await page.getByLabel('Workspace',{exact:true}).fill('abay');await page.getByLabel('Email',{exact:true}).fill('almaz@abay.example');
 await page.getByLabel('Password',{exact:true}).fill(password);await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await expect(page.getByRole('heading',{name:'Journal workspace'})).toBeVisible({timeout:20000});
 const sidebar=page.getByRole('navigation',{name:'Main navigation'});
 await sidebar.getByRole('button',{name:'Fiscal periods',exact:true}).click();
 await expect(page.getByText('Pagume').first()).toBeVisible({timeout:15000});
 await sidebar.getByRole('button',{name:'Chart of accounts',exact:true}).click();
 await expect(page.getByText('Trade receivables').first()).toBeVisible({timeout:15000});
 await page.screenshot({path:`${out}/signed-in.png`,fullPage:true});
});
await step('the practice workspace uses its own password, not the administrator\'s',async()=>{
 const ctx=page.context();
 const tryLogin=async pw=>(await ctx.request.post(base+'/api/v1/auth/login',{headers:{Origin:base,'Content-Type':'application/json'},data:{tenant:'demo',email:'admin@serk.demo',password:pw}})).status();
 if(await tryLogin(password)===200)throw new Error('admin password opens the practice workspace');
 const ok=await tryLogin(globalThis.practicePassword);if(ok!==200)throw new Error('practice login '+ok);
});
await step('setup cannot run a second time',async()=>{
 const r=await page.request.post(base+'/setup/api',{headers:{Origin:base,'Content-Type':'application/json'},data:{workspace:'evil',company_name:'X',calendar:'GREGORIAN',year_start:'2026-01-01',admin_name:'X',admin_email:'x@x.example',admin_password:'abcdefghijklmnop'},maxRedirects:0});
 if(![303,404,409].includes(r.status())&&r.status()<300)throw new Error('second setup returned '+r.status());
 await page.goto(base+'/setup');await expect(page).not.toHaveURL(/\/setup/);
});
await browser.close();
if(errors.length){console.log('Browser errors:\n'+errors.join('\n'));failures++;}
console.log(failures?'FAIL':'PASS','office setup');process.exitCode=failures?1:0;
