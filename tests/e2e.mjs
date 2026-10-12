import {chromium,expect} from '../web/node_modules/@playwright/test/index.mjs';
import {readFileSync,mkdirSync} from 'node:fs';
import {fixtureCode} from './totp.mjs';
const cfg=JSON.parse(readFileSync(process.env.SERK_FIXTURE_FILE||'.local/verification/bootstrap.json','utf8'));
const browser=await chromium.launch({headless:true,executablePath:process.env.SERK_BROWSER_EXECUTABLE||undefined,
 args:process.env.SERK_BROWSER_ARGS_JSON?JSON.parse(process.env.SERK_BROWSER_ARGS_JSON):[]});
const page=await browser.newPage({viewport:{width:1440,height:1000}});
const errors=[];page.on('pageerror',e=>errors.push(e.message));
const resultDir=process.env.SERK_RESULTS_DIR||'test-results';
mkdirSync(resultDir+'/screenshots',{recursive:true});
async function screenshot(name){await page.screenshot({path:resultDir+'/screenshots/'+name+'.png',fullPage:true})}
async function signIn(user){await page.getByLabel('Workspace',{exact:true}).fill(cfg.slug);await page.getByLabel('Email',{exact:true}).fill(user.email);await page.getByLabel('Password',{exact:true}).fill(user.password);await page.getByRole('button',{name:'Sign in',exact:true}).click();await page.getByLabel('Authenticator code',{exact:true}).fill(fixtureCode(user.mfaSecret));await page.getByRole('button',{name:'Verify code',exact:true}).click();await expect(page.getByRole('heading',{name:'Journal workspace'})).toBeVisible()}
async function transition(action,reason){await page.getByRole('button',{name:action+' journal',exact:true}).click();await page.getByLabel('Reason',{exact:true}).fill(reason);await page.getByRole('button',{name:'Confirm '+action.toLowerCase(),exact:true}).click();await expect(page.getByRole('dialog')).toHaveCount(0)}
try{
 await page.goto('http://localhost:8080');await expect(page.getByText('Welcome back.',{exact:true})).toBeVisible();await screenshot('01-sign-in');
 await signIn(cfg.users[0]);await screenshot('02-empty-workspace');
 await page.keyboard.press('Control+k');await expect(page.getByRole('dialog',{name:'Command palette'})).toBeVisible();await page.getByRole('button',{name:'Create journal',exact:true}).click();
 await page.getByLabel('Accounting date',{exact:true}).fill('2026-09-14');await page.getByLabel('Description',{exact:true}).fill('Acceptance evidence · opening capital');
 await page.getByLabel('Account line 1',{exact:true}).selectOption({label:'1000 · Bank'});await page.getByLabel('Account line 2',{exact:true}).selectOption({label:'3000 · Capital'});
 await page.getByLabel('Debit line 1',{exact:true}).fill('250000');await page.getByLabel('Credit line 2',{exact:true}).fill('250000');await page.getByLabel('Reason / supporting reference',{exact:true}).fill('Synthetic browser acceptance test. Initial capital receipt.');
 await screenshot('03-journal-entry');await page.getByRole('button',{name:'Save draft',exact:true}).click();await expect(page.getByRole('heading',{name:/JRN-FY2026-000001/})).toBeVisible();
 await transition('Submit','Prepared and supporting evidence attached to acceptance test.');await expect(page.getByRole('button',{name:'Approve journal',exact:true})).toHaveCount(0);
 await page.getByRole('button',{name:'Open profile for accountant',exact:true}).click();await expect(page.getByRole('dialog',{name:'Your profile'})).toBeVisible();await page.getByRole('dialog').getByRole('button',{name:'Sign out',exact:true}).click();await signIn(cfg.users[1]);await page.getByRole('button',{name:'JRN-FY2026-000001',exact:true}).click();
 await transition('Approve','Independent approver verified the original source.');await transition('Post','Release approved entry to the general ledger.');await expect(page.locator('.badge.posted')).toBeVisible();await screenshot('04-posted-journal');
 await page.getByRole('button',{name:'Trial balance',exact:true}).click();await expect(page.getByText('Debits and credits reconcile.',{exact:true})).toBeVisible();await expect(page.locator('tfoot')).toContainText('250,000.00');await screenshot('05-trial-balance');
 await page.getByRole('button',{name:'Bank',exact:true}).click();await expect(page.getByRole('heading',{name:'General ledger',exact:true})).toBeVisible();
 await expect(page.locator('.ledger-totals')).toContainText('250,000.00');await expect(page.getByRole('button',{name:'JRN-FY2026-000001',exact:true})).toBeVisible();await screenshot('11-general-ledger');
 await page.getByRole('button',{name:'JRN-FY2026-000001',exact:true}).click();await expect(page.getByRole('heading',{name:/JRN-FY2026-000001/})).toBeVisible();
 await page.getByRole('button',{name:'Ledger integrity',exact:true}).click();await expect(page.getByRole('heading',{name:'Local integrity checks passed',exact:true})).toBeVisible();await screenshot('12-ledger-integrity');
 await page.getByRole('button',{name:'Audit history',exact:true}).click();await expect(page.getByText('#4 · journals.posted',{exact:true})).toBeVisible();await screenshot('06-audit-history');
 await expect(page.getByText(/MUI X Missing license key/)).toHaveCount(0);
 await page.getByRole('button',{name:'Show details'}).first().click();await expect(page.getByRole('dialog',{name:'Record details'})).toContainText('Event hash');await expect(page.getByRole('button',{name:'Close details',exact:true})).toBeInViewport({ratio:1});await page.waitForTimeout(400);await screenshot('06b-audit-evidence');await page.getByRole('button',{name:'Close details',exact:true}).click();

 // Exercise a real three-source-line FX rounding journal and close preview.
 await page.getByRole('button',{name:'Journals',exact:true}).click();
 await page.getByRole('button',{name:'New journal',exact:true}).click();
 await page.getByLabel('Accounting date',{exact:true}).fill('2026-09-15');await page.getByLabel('Description',{exact:true}).fill('FX rounding acceptance');
 await page.getByLabel('Currency',{exact:true}).selectOption('USD');await page.getByLabel('Rate · ETB per USD',{exact:true}).fill('0.5');
 await page.getByRole('button',{name:'Add line',exact:true}).click();
 for(const n of [1,2]){await page.getByLabel('Account line '+n,{exact:true}).selectOption({label:'1000 · Bank'});await page.getByLabel('Debit line '+n,{exact:true}).fill('0.01')}
 await page.getByLabel('Account line 3',{exact:true}).selectOption({label:'3000 · Capital'});await page.getByLabel('Credit line 3',{exact:true}).fill('0.02');
 await page.getByLabel('Reason / supporting reference',{exact:true}).fill('Synthetic foreign currency rounding acceptance');await page.getByRole('button',{name:'Save draft',exact:true}).click();
 await expect(page.getByText('FX conversion rounding · System rounding',{exact:true})).toBeVisible();await screenshot('08-fx-rounding');
 await page.getByRole('button',{name:'Fiscal periods',exact:true}).click();await page.getByRole('button',{name:'Review close P09',exact:true}).click();
 await expect(page.getByText('Close is blocked. Finish or void these journals, then review again.',{exact:true})).toBeVisible();await screenshot('09-close-blocked');
 await page.getByRole('button',{name:'Journals',exact:true}).click();await page.getByRole('button',{name:'JRN-FY2026-000002',exact:true}).click();await transition('Void','Void synthetic rounding draft before close');
 await page.getByRole('button',{name:'Fiscal periods',exact:true}).click();await page.getByRole('button',{name:'Review close P09',exact:true}).click();
 await page.getByLabel('Close reason',{exact:true}).fill('All synthetic journals resolved and balances checked');await page.getByRole('button',{name:'Confirm period close',exact:true}).click();
 await expect(page.getByRole('row').filter({has:page.getByText('P09',{exact:true})})).toContainText('closed');await screenshot('10-period-closed');
 await page.setViewportSize({width:390,height:844});await page.getByRole('button',{name:'Journals',exact:true}).click();await expect(page.getByRole('heading',{name:'Journal workspace'})).toBeVisible();await screenshot('07-mobile');
 await page.getByRole('button',{name:'General ledger',exact:true}).click();await expect(page.locator('.ledger-totals')).toBeVisible();await screenshot('13-mobile-ledger');
 const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>window.innerWidth);if(overflow)throw new Error('Unexpected horizontal viewport overflow');
 if(errors.length)throw new Error(errors.join('\n'));
 console.log('PASS: real browser MFA login → journal → submit → independent approval → post → trial balance → general-ledger drill-down → source journal → integrity → audit; FX rounding, blocked close, void and successful period close; command palette, mobile journal/ledger layouts, no browser errors.');
}finally{await browser.close()}
