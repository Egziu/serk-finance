// Release acceptance for Go's own discovery and execution JSON streams.
export const nativeTests=Object.freeze([
  'TestNativeConcurrentIdempotency',
  'TestNativeConcurrentPosting',
  'TestNativeCloseSerializesWithPosting',
  'TestNativeDimensionChangeSerializesWithPosting',
  'TestNativeChartCycleSnapshotConflict',
  'TestNativeMFAReplaySerialization',
  'TestNativeCloseSerializesWithCreation',
  'TestNativeRuntimeIdentityBoundaries',
]);
const key=(pkg,name)=>pkg+'::'+name;
const nativeKeys=new Set(nativeTests.map(name=>key('serk.finance/tests',name)));
export function requireUnfilteredGoFlags(value){
  // Go's environment can contain persistent GOFLAGS as well as shell values.
  // Reject selectors instead of silently accepting filtered subtests/fuzz seeds.
  const match=value.match(/(?:^|\s)["']?-(?:test\.)?(run|skip|short|list|fuzz)(?:=|\s|["']|$)/);
  if(match)throw Error('Release verification forbids GOFLAGS -'+match[1]+'; run targeted tests separately');
}
function events(text){
  return text.split('\n').filter(line=>line.trim()).flatMap(line=>{
    // The harness also records Go's module-download messages from stderr.
    if(line.startsWith('go: '))return [];
    const event=JSON.parse(line);
    if(!event || typeof event.Action!=='string' || typeof event.Package!=='string')throw Error('Invalid Go JSON event');
    return [event];
  });
}
export function assessGoEvidence(discoveryText,executionText,{native=false}={}){
  const discovery=events(discoveryText),execution=events(executionText);
  const expected=new Set();
  for(const event of discovery){
    if(event.Action!=='output')continue;
    for(const name of (event.Output || '').split('\n').map(line=>line.trim())){
      if(/^(Test|Fuzz)[A-Za-z0-9_]+$/.test(name))expected.add(key(event.Package,name));
    }
  }
  const terminals=new Map(),packagePasses=new Set(),duplicates=[];
  for(const event of execution){
    if(!event.Test){if(event.Action==='pass')packagePasses.add(event.Package);continue;}
    if(!['pass','fail','skip'].includes(event.Action))continue;
    const id=key(event.Package,event.Test);
    if(terminals.has(id))duplicates.push(id);
    terminals.set(id,event.Action);
  }
  const missing=[...expected].filter(id=>!terminals.has(id));
  const unexpectedSkips=execution.filter(event=>event.Test && event.Action==='skip' && (native || !nativeKeys.has(key(event.Package,event.Test)))).map(event=>key(event.Package,event.Test));
  const failed=execution.filter(event=>event.Action==='fail');
  const missingPackages=[...new Set([...expected].map(id=>id.split('::')[0]))].filter(pkg=>!packagePasses.has(pkg));
  const absentNativeDefinitions=[...nativeKeys].filter(id=>!expected.has(id));
  const nativePassed=[...nativeKeys].filter(id=>terminals.get(id)==='pass');
  const missingNativePasses=native?[...nativeKeys].filter(id=>terminals.get(id)!=='pass'):[];
  const errors=[];
  if(!expected.size)errors.push('Test discovery found no tests');
  if(discovery.some(event=>event.Action==='fail'))errors.push('Go test discovery failed');
  if(missing.length)errors.push('Discovered tests missing from execution: '+missing.join(', '));
  if(unexpectedSkips.length)errors.push('Disallowed skipped tests: '+unexpectedSkips.join(', '));
  if(failed.length)errors.push('Go reported failed tests or packages');
  if(missingPackages.length)errors.push('Packages lack successful completion: '+missingPackages.join(', '));
  if(absentNativeDefinitions.length)errors.push('Required native tests absent from discovery: '+absentNativeDefinitions.join(', '));
  if(missingNativePasses.length)errors.push('Native tests lack PASS records: '+missingNativePasses.join(', '));
  if(duplicates.length)errors.push('Duplicate test completion records: '+duplicates.join(', '));
  return {
    status:errors.length?'FAIL':'PASS',backend:native?'native-postgresql':'pglite',
    expected_top_level_tests:expected.size,
    observed_top_level_tests:[...expected].filter(id=>terminals.has(id)).length,
    passed:execution.filter(event=>event.Action==='pass' && event.Test).length,
    failed:failed.filter(event=>event.Test).length,
    skipped:execution.filter(event=>event.Action==='skip' && event.Test).map(event=>event.Test),
    native_tests:{required:nativeKeys.size,passed:nativePassed.length,status:native?(missingNativePasses.length?'FAIL':'PASS'):'NOT_RUN'},
    missing,unexpected_skips:unexpectedSkips,errors,
  };
}
