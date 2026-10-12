import test from 'node:test';
import assert from 'node:assert/strict';
import {assessGoEvidence,nativeTests,requireUnfilteredGoFlags} from './go-evidence.mjs';

// Synthetic events test the acceptance decision; they are not native DB proof.
const pkg='serk.finance/tests';
const names=['TestFinancialLifecycle','FuzzMoney',...nativeTests];
const discovery=names.map(name=>({Action:'output',Package:pkg,Output:name+'\n'}));
const json=rows=>rows.map(row=>JSON.stringify(row)).join('\n');
const complete=(native=false)=>[...names.map(name=>({Action:!native && nativeTests.includes(name)?'skip':'pass',Package:pkg,Test:name})),{Action:'pass',Package:pkg}];
const assess=(rows,{native=false,listed=discovery}={})=>assessGoEvidence(json(listed),json(rows),{native});

test('embedded run accounts for every test and only the eight native skips',()=>{
  const result=assess(complete());assert.equal(result.status,'PASS');assert.equal(result.skipped.length,8);assert.equal(result.native_tests.status,'NOT_RUN');
});
test('native decision requires every discovered test and all eight native passes',()=>{
  const result=assess(complete(true),{native:true});assert.equal(result.status,'PASS');assert.equal(result.native_tests.passed,8);
});
test('zero executed tests cannot pass despite a successful package exit',()=>assert.equal(assess([{Action:'pass',Package:pkg}]).status,'FAIL'));
test('a filtered ordinary test cannot disappear',()=>assert.equal(assess(complete().filter(row=>row.Test!=='TestFinancialLifecycle')).status,'FAIL'));
test('a filtered fuzz seed root cannot disappear',()=>assert.equal(assess(complete().filter(row=>row.Test!=='FuzzMoney')).status,'FAIL'));
test('native skips cannot pass',()=>assert.equal(assess(complete(),{native:true}).status,'FAIL'));
test('seven native passes are insufficient',()=>assert.equal(assess(complete(true).filter(row=>row.Test!==nativeTests[0]),{native:true}).status,'FAIL'));
test('only native tests is an incomplete full release run',()=>assert.equal(assess(complete(true).filter(row=>!row.Test || nativeTests.includes(row.Test)),{native:true}).status,'FAIL'));
test('ordinary test and subtest skips fail closed',()=>{
  assert.equal(assess(complete().map(row=>row.Test==='TestFinancialLifecycle'?{...row,Action:'skip'}:row)).status,'FAIL');
  assert.equal(assess([...complete(),{Action:'skip',Package:pkg,Test:'TestFinancialLifecycle/omitted'}]).status,'FAIL');
});
test('package failure cannot be hidden by passing test records',()=>assert.equal(assess([...complete(),{Action:'fail',Package:pkg}]).status,'FAIL'));
test('empty discovery and missing native definitions fail closed',()=>{
  assert.equal(assess(complete(),{listed:[]}).status,'FAIL');
  assert.equal(assess(complete(),{listed:discovery.filter(row=>row.Output!==nativeTests[0]+'\n')}).status,'FAIL');
});
test('missing package completion and duplicate test results fail closed',()=>{
  assert.equal(assess(complete().filter(row=>row.Test)).status,'FAIL');
  assert.equal(assess([...complete(),complete()[0]]).status,'FAIL');
});
test('malformed evidence fails instead of silently dropping records',()=>assert.throws(()=>assessGoEvidence(json(discovery),'malformed JSON')));
test('release permits the archive build flag but rejects test selection flags',()=>{
  requireUnfilteredGoFlags('-buildvcs=false');
  for(const flag of ['-run=TestFinancialLifecycle/subtest','-skip=Native','-short','-list=Test','-fuzz=FuzzMoney','"-run=TestA TestB"',"'-test.run=TestA'"]){
    assert.throws(()=>requireUnfilteredGoFlags('-buildvcs=false '+flag));
  }
});
