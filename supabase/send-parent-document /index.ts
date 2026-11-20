// Send one learner's PDF to the parent email recorded on that learner.
// The function independently verifies the signed-in staff member, school membership,
// learner email and explicit parentEmailConsent flag before contacting Resend.
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
const env=(k:string)=>Deno.env.get(k)||"";
serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors}); if(req.method!=="POST")return reply({error:"POST required"},405);
 try{
  const url=env("SUPABASE_URL"),anon=env("SUPABASE_ANON_KEY"),service=env("SUPABASE_SERVICE_ROLE_KEY"),resend=env("RESEND_API_KEY"),from=env("PARENT_DOCUMENT_FROM_EMAIL");
  if(!url||!anon||!service||!resend||!from)return reply({error:"Email delivery is not configured. Set Supabase and Resend function secrets."},500);
  const auth=req.headers.get("Authorization")||""; if(!/^Bearer\s+\S+/i.test(auth))return reply({error:"Sign in is required."},401);
  const userRes=await fetch(`${url}/auth/v1/user`,{headers:{apikey:anon,Authorization:auth}}); if(!userRes.ok)return reply({error:"Your session is invalid or expired."},401);
  const user=await userRes.json();
  const body=await req.json(); const learnerId=String(body.learnerId||"").slice(0,100), documentType=String(body.documentType||"");
  const fileName=String(body.fileName||"learner-document.pdf").replace(/[^a-zA-Z0-9._ -]/g,"_").slice(0,100), base64=String(body.pdfBase64||"");
  if(!learnerId||! ["fee_statement","examination_report"].includes(documentType))return reply({error:"Invalid learner or document type."},400);
  if(!base64||base64.length>12_000_000)return reply({error:"PDF is missing or exceeds the 9 MB limit."},413);
  const bytes=Uint8Array.from(atob(base64),c=>c.charCodeAt(0)); if(bytes.length<8||new TextDecoder().decode(bytes.slice(0,5))!=="%PDF-")return reply({error:"The attachment is not a valid PDF."},400);
  const memberships=await fetch(`${url}/rest/v1/school_memberships?user_id=eq.${encodeURIComponent(user.id)}&status=eq.active&select=school_id,role`,{headers:{apikey:anon,Authorization:auth}});
  if(!memberships.ok)return reply({error:"Could not verify your school membership."},403);
  const rows=await memberships.json(); const allowedRoles=["school_admin","teacher","bursar","accountant"];
  let learner:any=null, schoolId="";
  for(const membership of rows){if(!allowedRoles.includes(String(membership.role)))continue;
   const stateRes=await fetch(`${url}/rest/v1/school_state_shared?id=eq.${encodeURIComponent(membership.school_id)}&select=data`,{headers:{apikey:anon,Authorization:auth}}); if(!stateRes.ok)continue;
   const stateRows=await stateRes.json(); const found=(stateRows?.[0]?.data?.learners||[]).find((l:any)=>String(l.id)===learnerId);
   if(found){learner=found;schoolId=membership.school_id;break;}
  }
  if(!learner||!schoolId)return reply({error:"Learner was not found in a school you are authorised to access."},404);
  const recipient=String(learner.parentEmail||"").trim().toLowerCase();
  if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient))return reply({error:"A valid parent/guardian email is not recorded for this learner."},400);
  if(learner.parentEmailConsent!==true)return reply({error:"Parent/guardian email consent has not been recorded for this learner."},403);
  const fileBytes=bytes.byteLength;
  const mail=await fetch("https://api.resend.com/emails",{method:"POST",headers:{Authorization:`Bearer ${resend}`,"Content-Type":"application/json"},body:JSON.stringify({from,to:[recipient],subject:documentType==="fee_statement"?"Learner fee statement":"Learner examination report",text:`Please find attached the requested ${documentType.replace("_"," ")} for ${String(learner.name||"the learner").slice(0,100)}. This email was sent by the school through JengaEdu.`,attachments:[{filename:fileName,content:base64}],tags:[{name:"system",value:"jengaedu"},{name:"document_type",value:documentType}]})});
  const provider=await mail.json().catch(()=>({})); if(!mail.ok)return reply({error:String(provider?.message||provider?.error||`Email provider rejected request (${mail.status}).`).slice(0,260)},502);
  // Delivery log is best-effort; email acceptance is returned only after Resend accepts it.
  const log=await fetch(`${url}/rest/v1/notification_delivery_logs`,{method:"POST",headers:{apikey:service,Authorization:`Bearer ${service}`,"Content-Type":"application/json",Prefer:"return=minimal"},body:JSON.stringify({learner_id:learnerId,recipient_email:recipient,channel:"email",message_type:documentType,provider:"Resend",status:"submitted",provider_response:{id:provider?.id||null,file_bytes:fileBytes,school_id:schoolId},failure_reason:null})});
  if(!log.ok)console.error("Could not write parent email delivery log",log.status,await log.text());
  return reply({accepted:true,message:"Email accepted by Resend.",emailId:provider?.id||null});
 }catch(e){console.error("send-parent-document",e);return reply({error:String((e as Error)?.message||e).slice(0,260)},500);}
});
