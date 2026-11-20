// JengaEdu SMS OTP password recovery.
// Requires the jenga_password_reset_otps table migration and Africa's Talking secrets.
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const env = (k: string) => Deno.env.get(k) || "";
const normalizePhone = (v: unknown) => { let n=String(v||"").trim().replace(/[\s().-]/g,""); if(n.startsWith("00"))n="+"+n.slice(2); if(/^0[17]\d{8}$/.test(n))n="+254"+n.slice(1); else if(/^254[17]\d{8}$/.test(n))n="+"+n; else if(/^[17]\d{8}$/.test(n))n="+254"+n; return /^\+254[17]\d{8}$/.test(n)?n:""; };
const hash = async (v: string) => { const b=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(v)); return [...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,"0")).join(""); };
async function sendSms(phone: string, message: string) {
  const username=env("AFRICASTALKING_USERNAME"), apiKey=env("AFRICASTALKING_API_KEY");
  if(!username||!apiKey)throw new Error("Africa's Talking is not configured. Set AFRICASTALKING_USERNAME and AFRICASTALKING_API_KEY.");
  const form=new URLSearchParams({username,to:phone,message}); const sender=env("AFRICASTALKING_SENDER_ID"); if(sender)form.set("from",sender);
  const r=await fetch("https://api.africastalking.com/version1/messaging",{method:"POST",headers:{apiKey,Accept:"application/json","Content-Type":"application/x-www-form-urlencoded"},body:form});
  const body=await r.json().catch(()=>({})); if(!r.ok)throw new Error(`SMS provider error (${r.status}): ${String(body?.SMSMessageData?.Message||"request rejected").slice(0,180)}`);
  const recipient=body?.SMSMessageData?.Recipients?.[0]; if(!recipient || Number(recipient.statusCode)!==101)throw new Error("SMS provider did not accept the OTP message.");
}
serve(async req => {
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors}); if(req.method!=="POST")return reply({error:"POST required"},405);
  try {
    const url=env("SUPABASE_URL"), service=env("SUPABASE_SERVICE_ROLE_KEY"), pepper=env("PASSWORD_OTP_PEPPER");
    if(!url||!service||!pepper)return reply({error:"Password recovery is not configured. Set SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY and PASSWORD_OTP_PEPPER."},500);
    const db=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
    const body=await req.json(), action=String(body.action||""), email=String(body.email||"").trim().toLowerCase(), phone=normalizePhone(body.phone);
    if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)||!phone)return reply({error:"Enter the registered email and a valid Kenyan phone number."},400);
    if(action==="request") {
      // Always return a generic success response to avoid exposing registered accounts.
      const generic={ok:true,message:"If the details match an eligible school administrator, an OTP will be sent."};
      const {data:users,error:userErr}=await db.auth.admin.listUsers({page:1,perPage:1000}); if(userErr)throw userErr;
      const user=users.users.find(u=>(u.email||"").toLowerCase()===email); if(!user)return reply(generic);
      const {data:members}=await db.from("school_memberships").select("school_id,role,status").eq("user_id",user.id).eq("role","school_admin").eq("status","active");
      let verified=false;
      for(const m of members||[]) { const {data:state}=await db.from("school_state_shared").select("data").eq("id",m.school_id).maybeSingle(); if(normalizePhone(state?.data?.settings?.phone)===phone){verified=true;break;} }
      if(!verified)return reply(generic);
      const {data:old}=await db.from("jenga_password_reset_otps").select("created_at").eq("email",email).maybeSingle();
      if(old?.created_at && Date.now()-new Date(old.created_at).getTime()<60_000)return reply({error:"Please wait one minute before requesting another OTP."},429);
      const code=String(crypto.getRandomValues(new Uint32Array(1))[0]%1_000_000).padStart(6,"0");
      const codeHash=await hash(`${email}|${phone}|${code}|${pepper}`), expiresAt=new Date(Date.now()+10*60_000).toISOString();
      const {error:saveErr}=await db.from("jenga_password_reset_otps").upsert({email,phone,code_hash:codeHash,expires_at:expiresAt,attempts:0,verified_at:null,created_at:new Date().toISOString()},{onConflict:"email"}); if(saveErr)throw saveErr;
      await sendSms(phone,`JengaEdu password reset code: ${code}. Expires in 10 minutes. Do not share this code.`);
      return reply(generic);
    }
    if(action==="reset") {
      const code=String(body.code||"").trim(), password=String(body.password||"");
      if(!/^\d{6}$/.test(code)||password.length<8)return reply({error:"Enter a valid 6-digit OTP and a password of at least 8 characters."},400);
      const {data:otp,error:otpErr}=await db.from("jenga_password_reset_otps").select("*").eq("email",email).maybeSingle(); if(otpErr)throw otpErr;
      if(!otp||otp.phone!==phone||new Date(otp.expires_at).getTime()<Date.now()||Number(otp.attempts)>=5)return reply({error:"The OTP is invalid or expired. Request a new code."},400);
      const expected=await hash(`${email}|${phone}|${code}|${pepper}`);
      if(expected!==otp.code_hash){await db.from("jenga_password_reset_otps").update({attempts:Number(otp.attempts)+1}).eq("email",email);return reply({error:"The OTP is incorrect."},400);}
      const {data:users,error:userErr}=await db.auth.admin.listUsers({page:1,perPage:1000}); if(userErr)throw userErr;
      const user=users.users.find(u=>(u.email||"").toLowerCase()===email); if(!user)return reply({error:"Account could not be verified."},400);
      const {data:members}=await db.from("school_memberships").select("school_id,role,status").eq("user_id",user.id).eq("role","school_admin").eq("status","active");
      let verified=false; for(const m of members||[]){const {data:state}=await db.from("school_state_shared").select("data").eq("id",m.school_id).maybeSingle();if(normalizePhone(state?.data?.settings?.phone)===phone){verified=true;break;}}
      if(!verified)return reply({error:"Account details could not be verified."},400);
      const {error:updateErr}=await db.auth.admin.updateUserById(user.id,{password}); if(updateErr)throw updateErr;
      await db.from("jenga_password_reset_otps").delete().eq("email",email);
      return reply({ok:true,message:"Password changed successfully."});
    }
    return reply({error:"Unsupported action."},400);
  } catch(e) { console.error("password-recovery",e); return reply({error:String((e as Error)?.message||e).slice(0,260)},500); }
});
