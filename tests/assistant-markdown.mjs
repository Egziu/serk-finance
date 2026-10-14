// Unit test of the assistant panel's Markdown renderer and conversation history. Transpiles the
// component with Vite's TypeScript transform, then renders on the server. Run: node tests/assistant-markdown.mjs
import {mkdirSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(new URL('../web/package.json',import.meta.url));
const {transformWithOxc}=await import(require.resolve('vite'));
const out=new URL('../web/.unit-build/',import.meta.url);
rmSync(out,{recursive:true,force:true});mkdirSync(out,{recursive:true});
for(const name of ['AssistantPanel.tsx','api.ts']){
 const src=readFileSync(new URL('../web/src/'+name,import.meta.url),'utf8');
 const js=(await transformWithOxc(src,name,{lang:name.endsWith('x')?'tsx':'ts',jsx:{runtime:'automatic'}})).code.replace(/from "\.\/api"/g,'from "./api.mjs"').replace(/from '\.\/api'/g,"from './api.mjs'");
 writeFileSync(new URL(name.replace(/\.tsx?$/,'.mjs'),out),js);
}
const {Markdown,history}=await import(new URL('AssistantPanel.mjs',out));
const {renderToStaticMarkup}=require('react-dom/server');
const {createElement}=require('react');
const render=text=>{const t=Date.now();const html=renderToStaticMarkup(createElement(Markdown,{text}));assert.ok(Date.now()-t<1000,'slow render');return html;};
let failures=0;
const check=(name,fn)=>{try{fn();console.log('PASS',name);}catch(e){failures++;console.log('FAIL',name,e.message);}};
check('lines that look like tables or headings but are not still terminate',()=>{
 for(const text of ['| a | b','#Total','##### five','   # indented','|','||','x\n| a | b\ny','**','# ']){render(text);}
});
check('a table of only a separator row renders nothing and does not crash',()=>{assert.equal(render('|---|---|'),'');});
check('tables, lists, headings and bold render as elements, text never as HTML',()=>{
 const html=render('## Cash\n| Account | Balance |\n|---|---:|\n| CBE | **1,000.00** |\n- one\n- two\n<script>alert(1)</script>');
 assert.match(html,/<h4>Cash<\/h4>/);assert.match(html,/<th>Account<\/th>/);assert.match(html,/<strong>1,000.00<\/strong>/);assert.match(html,/<li>two<\/li>/);
 assert.ok(!html.includes('<script>'));
});
check('failed exchanges are not resent and the history alternates from a user turn',()=>{
 const h=history([{role:'assistant',content:'hello'},{role:'user',content:'q1'},{role:'assistant',content:'a1'},{role:'user',content:'q2',failed:true},{role:'assistant',content:'error',error:true},{role:'user',content:'q3'},{role:'user',content:'q4'}]);
 assert.deepEqual(h.map(x=>x.role),['user','assistant','user']);assert.equal(h[2].content,'q4','an unanswered question is replaced by the next one');
});
check('every message sent fits the server limit of 8000 bytes, long replies keep their end',()=>{
 const long='ብር '.repeat(4000)+'END';
 const h=history([{role:'user',content:'q1'},{role:'assistant',content:long},{role:'user',content:'q2'}]);
 const size=s=>new TextEncoder().encode(s).length;
 assert.ok(h.every(m=>size(m.content)<=8000),'oversized message');assert.ok(h[1].content.endsWith('END'));
});
rmSync(out,{recursive:true,force:true});
console.log(failures?'FAIL':'PASS','assistant markdown');process.exitCode=failures?1:0;
