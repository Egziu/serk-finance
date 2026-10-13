import { useState, useEffect } from "react";
import { KeyRound, LogOut, ShieldCheck, X } from "lucide-react";
import type { Reference, Session } from "./types";
import { api } from "./api";

// What the sign-in screen knew; the session API does not return email or workspace.
export type Identity = { tenant: string; email: string; signedInAt: string; mfa: boolean };
const KEY = "serk.identity";
export function saveIdentity(i: Identity) {
  try {
    sessionStorage.setItem(KEY, JSON.stringify(i));
  } catch {
    /* storage unavailable: the profile shows what the session API returns */
  }
}
export function loadIdentity(): Identity | null {
  try {
    const raw = sessionStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as Identity) : null;
  } catch {
    return null;
  }
}
export function clearIdentity() {
  try {
    sessionStorage.removeItem(KEY);
  } catch {
    /* nothing stored */
  }
}

type Props={session:Session;identity:Identity|null;company:string;reference:Reference|null;locked:boolean;onClose:()=>void;onSignOut:()=>void};
type MFAStatus={enrolled:boolean;required:boolean;secret?:string;otpauth_uri?:string;dev_code?:string};
export function ProfileModal({session,identity,company,locked,onClose,onSignOut}:Props){
 const [status,setStatus]=useState<MFAStatus|null>(null),[error,setError]=useState(""),[busy,setBusy]=useState(false),[editing,setEditing]=useState(false);
 const [password,setPassword]=useState(""),[currentCode,setCurrentCode]=useState(""),[newCode,setNewCode]=useState("");
 useEffect(()=>{let active=true;void api<MFAStatus>("/profile/mfa",company).then(s=>{if(active)setStatus(s)}).catch(e=>{if(active)setError(e.message)});return()=>{active=false}},[company]);
 async function change(disable:boolean){
  if(!password||status?.enrolled&&currentCode.length!==6||!disable&&newCode.length!==6){setError("Enter your password and the required authenticator codes.");return}
  setBusy(true);setError("");try{await api("/profile/mfa/"+(disable?"disable":"enable"),company,{method:"POST",csrf:session.csrf_token,body:{password,current_code:currentCode,secret:disable?"":status?.secret,code:disable?"":newCode}});setPassword("");setCurrentCode("");setNewCode("");clearIdentity();window.location.reload();}catch(e){setError(e instanceof Error?e.message:"Could not update authentication.")}finally{setBusy(false)}
 }
 const [pwOpen,setPwOpen]=useState(false),[pwCurrent,setPwCurrent]=useState(""),[pwNew,setPwNew]=useState(""),[pwConfirm,setPwConfirm]=useState(""),[pwError,setPwError]=useState("");
 async function changePassword(){
  if(pwNew.length<14){setPwError("The new password needs at least 14 characters.");return}
  if(pwNew!==pwConfirm){setPwError("The new passwords do not match.");return}
  if(pwNew===pwCurrent){setPwError("Choose a password different from the current one.");return}
  setBusy(true);setPwError("");try{await api("/profile/password",company,{method:"POST",csrf:session.csrf_token,body:{current_password:pwCurrent,new_password:pwNew}});setPwCurrent("");setPwNew("");setPwConfirm("");clearIdentity();window.location.reload();}catch(e){setPwError(e instanceof Error?e.message:"Could not change the password.")}finally{setBusy(false)}
 }
 return <div className="overlay"><section className="modal profile-modal" role="dialog" aria-modal="true" aria-label="Your profile"><button className="icon-btn" aria-label="Close profile" onClick={onClose}><X size={18}/></button><h2>{session.name}</h2><p>{identity?.email}</p><h3><ShieldCheck size={17}/> Two-factor authentication</h3>
 {error&&<div className="error" role="alert">{error}</div>}
 <p>{status?.enrolled?"Authenticator enabled.":"Authenticator not enrolled."}{status?.required?" Your organization requires two-factor authentication.":""}</p>
 <button className="secondary" disabled={busy||locked||!status} onClick={()=>{setEditing(!editing);setPassword("");setCurrentCode("");setNewCode("");}}>{status?.enrolled?"Replace authenticator":"Set up authenticator"}</button>
 {editing&&status&&<form className="finance-form" onSubmit={e=>{e.preventDefault();void change(false)}}><p>Authentication changes revoke every existing session. You will sign in again after saving.</p><label>Current password<input autoComplete="current-password" required type="password" value={password} onChange={e=>setPassword(e.target.value)}/></label>
 {status.enrolled&&<label>Code from your current authenticator<input required inputMode="numeric" pattern="[0-9]{6}" value={currentCode} onChange={e=>setCurrentCode(e.target.value)}/><small>Use a fresh code that was not used to sign in.</small></label>}
 <label>New authenticator secret<input readOnly value={status.secret||""}/></label><p>Add this secret to your authenticator app, then enter its confirmation code.</p><label>New authenticator code<input required inputMode="numeric" pattern="[0-9]{6}" value={newCode} onChange={e=>setNewCode(e.target.value)}/></label>
 {status.dev_code&&<p>Development confirmation code: {status.dev_code}</p>}<button className="primary" disabled={busy||locked}>Save authenticator</button>
 {status.enrolled&&!status.required&&<button type="button" disabled={busy||locked} onClick={()=>void change(true)}>Disable authenticator</button>}</form>}
 <h3><KeyRound size={17}/> Password</h3>
 <button className="secondary" disabled={busy||locked} onClick={()=>{setPwOpen(!pwOpen);setPwCurrent("");setPwNew("");setPwConfirm("");setPwError("");}}>Change password</button>
 {pwOpen&&<form className="finance-form" aria-label="Change password" onSubmit={e=>{e.preventDefault();void changePassword()}}><p>Changing your password signs you out everywhere. Use at least 14 characters.</p>
 {pwError&&<div className="error" role="alert">{pwError}</div>}
 <label>Current password<input autoComplete="current-password" required type="password" value={pwCurrent} onChange={e=>setPwCurrent(e.target.value)}/></label>
 <label>New password<input autoComplete="new-password" required minLength={14} maxLength={256} type="password" value={pwNew} onChange={e=>setPwNew(e.target.value)}/></label>
 <label>Confirm new password<input autoComplete="new-password" required minLength={14} maxLength={256} type="password" value={pwConfirm} onChange={e=>setPwConfirm(e.target.value)}/></label>
 <button className="primary" disabled={busy||locked}>Save new password</button></form>}
 <div className="profile-actions"><button className="secondary" onClick={onClose}>Close</button><button className="primary" disabled={busy||locked} onClick={onSignOut}><LogOut size={15}/> Sign out</button></div></section></div>;
}
