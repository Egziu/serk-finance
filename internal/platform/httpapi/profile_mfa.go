package httpapi

import (
 "encoding/json"
 "net/http"
 "time"
 "github.com/jackc/pgx/v5"
 "serk.finance/internal/auth"
 "serk.finance/internal/mfa"
)

type mfaStatusResponse struct {
 Enrolled bool `json:"enrolled"`
 Required bool `json:"required"`
 Secret string `json:"secret,omitempty"`
 OTPAuthURI string `json:"otpauth_uri,omitempty"`
 DevCode string `json:"dev_code,omitempty"`
}
func (s *Server) profileMFAStatus(w http.ResponseWriter,r *http.Request) {
 var status struct {Enrolled bool `json:"enrolled"`};var data json.RawMessage
 e:=s.scoped(r,func(tx pgx.Tx)error{return tx.QueryRow(r.Context(),"SELECT security.current_user_mfa_status()").Scan(&data)})
 if e!=nil{s.fail(w,r,e);return};if e=json.Unmarshal(data,&status);e!=nil{s.fail(w,r,e);return}
 res:=mfaStatusResponse{Enrolled:status.Enrolled,Required:s.Config.RequireMFA}
 key,e:=mfa.Generate("SERK Finance User");if e!=nil{s.fail(w,r,e);return};res.Secret=key.Secret();res.OTPAuthURI=key.URL()
 if s.Config.DevShowOTP {res.DevCode,_=mfa.CurrentCode(key.Secret(),time.Now())};write(w,200,res)
}
func (s *Server) profileMFAEnable(w http.ResponseWriter,r *http.Request){s.changeProfileMFA(w,r,false)}
func (s *Server) profileMFADisable(w http.ResponseWriter,r *http.Request){s.changeProfileMFA(w,r,true)}
func (s *Server) changeProfileMFA(w http.ResponseWriter,r *http.Request,disable bool) {
 if disable && s.Config.RequireMFA{s.fail(w,r,&problem{403,"mfa_required"});return}
 var in struct{Password string `json:"password"`;CurrentCode string `json:"current_code"`;Secret string `json:"secret"`;Code string `json:"code"`}
 if e:=decode(w,r,&in);e!=nil{s.fail(w,r,e);return}
 if len(in.Password)>256 || len(in.CurrentCode)>6 || len(in.Code)>6 || len(in.Secret)>128{s.fail(w,r,&problem{400,"invalid_credentials"});return}
 if !s.loginLimits.Allow("mfa-change:"+auth.Digest(s.token(r)),5){s.fail(w,r,&problem{429,"rate_limited"});return}
 if e:=s.scoped(r,func(tx pgx.Tx)error{return nil});e!=nil{s.fail(w,r,e);return}
 if e:=s.acquireLogin(r.Context());e!=nil{s.fail(w,r,&problem{503,"authentication_busy"});return};defer func(){<-s.loginSlots}()
 var record json.RawMessage
 e:=s.AuthDB.Transaction(r.Context(),func(tx pgx.Tx)error{return tx.QueryRow(r.Context(),"SELECT security.profile_auth_record($1)",s.token(r)).Scan(&record)})
 if e!=nil{s.fail(w,r,e);return}
 var user struct{ID string `json:"user_id"`;Hash string `json:"password_hash"`;MFASecret string `json:"mfa_secret"`;MFAVersion string `json:"mfa_version"`}
 if e=json.Unmarshal(record,&user);e!=nil{s.fail(w,r,&problem{401,"invalid_credentials"});return}
 if user.ID=="" || !auth.Verify(user.Hash,in.Password){s.fail(w,r,&problem{401,"invalid_credentials"});return}
 var oldVersion any;oldStep:=int64(-1)
 if user.MFASecret!=""{
  secret,err:=mfa.Decrypt(s.Config.MFAKey,user.ID,user.MFASecret);if err!=nil{s.fail(w,r,&problem{503,"authentication_unavailable"});return}
  var ok bool;oldStep,ok=mfa.MatchStep(secret,in.CurrentCode,time.Now());if !ok{s.fail(w,r,&problem{401,"invalid_credentials"});return};oldVersion=user.MFAVersion
 }
 var encrypted any;newStep:=int64(-1)
 if !disable {
  step,ok:=mfa.MatchStep(in.Secret,in.Code,time.Now());if !ok || !mfa.ValidSecret(in.Secret){s.fail(w,r,&problem{401,"invalid_credentials"});return}
  newStep=step;secret,err:=mfa.Encrypt(s.Config.MFAKey,user.ID,in.Secret);if err!=nil{s.fail(w,r,&problem{503,"authentication_unavailable"});return};encrypted=secret
 }
 var result json.RawMessage
 e=s.AuthDB.Transaction(r.Context(),func(tx pgx.Tx)error{return tx.QueryRow(r.Context(),"SELECT security.change_verified_mfa($1,$2,$3::uuid,$4,$5,$6,$7,$8)",s.token(r),user.Hash,oldVersion,oldStep,encrypted,newStep,disable,s.Config.RequireMFA).Scan(&result)})
 if e!=nil{s.fail(w,r,e);return};s.cookie(w,"",-1);write(w,200,result)
}
