// Public Safaricom callback endpoint. It verifies successful STK transactions by
// querying Daraja before calling the service-role-only database confirmation RPC.
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
const env=(k:string)=>Deno.env.get(k)||"";
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"Content-Type":"application/json"}});
async function tokenAndBase(){const key=env("MPESA_CONSUMER_KEY"),secret=env("MPESA_CONSUMER_SECRET");if(!key||!secret)throw new Error("Daraja credentials are missing");const base=env("MPESA_ENV")==="production"?"https://api.safaricom.co.ke":"https://sandbox.safaricom.co.ke";const r=await fetch(`${base}/oauth/v1/generate?grant_type=client_credentials`,{headers:{Authorization:`Basic ${btoa(`${key}:${secret}`)}`}});const d=await r.json().catch(()=>({}));if(!r.ok||!d.access_token)throw new Error("Could not authenticate with Daraja");return {token:d.access_token,base};}
serve(async req=>{
 if(req.method!=="POST")return json({ResultCode:1,ResultDesc:"POST required"},405);
 try{
  const url=env("SUPABASE_URL"),service=env("SUPABASE_SERVICE_ROLE_KEY"),shortcode=env("MPESA_SHORTCODE"),passkey=env("MPESA_PASSKEY");if(!url||!service||!shortcode||!passkey)throw new Error("Callback configuration is incomplete");
  const payload=await req.json();const callback=payload?.Body?.stkCallback;if(!callback?.CheckoutRequestID)return json({ResultCode:0,ResultDesc:"Callback received"});
  const checkout=String(callback.CheckoutRequestID),resultCode=String(callback.ResultCode),resultDescription=String(callback.ResultDesc||"");
  let receipt:string|null=null,amount:number|null=null,phone:string|null=null;
  if(resultCode==="0"){
   const {token,base}=await tokenAndBase();const timestamp=new Date().toISOString().replace(/[-T:.Z]/g,"").slice(0,14);const password=btoa(`${shortcode}${passkey}${timestamp}`);
   const query=await fetch(`${base}/mpesa/stkpushquery/v1/query`,{method:"POST",headers:{Authorization:`Bearer ${token}`,"Content-Type":"application/json"},body:JSON.stringify({BusinessShortCode:shortcode,Password:password,Timestamp:timestamp,CheckoutRequestID:checkout})});const q=await query.json().catch(()=>({}));
   if(!query.ok||String(q.ResultCode)!=="0")return json({ResultCode:0,ResultDesc:"Callback received; verification pending"});
   const meta=callback.CallbackMetadata?.Item||[];const get=(name:string)=>meta.find((x:any)=>x.Name===name)?.Value;
   receipt=String(get("MpesaReceiptNumber")||"");amount=Number(get("Amount"));phone=String(get("PhoneNumber")||"");
   if(!receipt||!Number.isFinite(amount))return json({ResultCode:0,ResultDesc:"Callback received; payment details require reconciliation"});
  }
  const rpc=await fetch(`${url}/rest/v1/rpc/confirm_subscription_payment`,{method:"POST",headers:{apikey:service,Authorization:`Bearer ${service}`,"Content-Type":"application/json"},body:JSON.stringify({p_checkout_request_id:checkout,p_result_code:resultCode,p_result_description:resultDescription,p_mpesa_receipt:receipt,p_paid_amount:amount,p_paid_phone:phone,p_callback:payload})});
  if(!rpc.ok){console.error("Payment confirmation RPC failed",rpc.status,await rpc.text());return json({ResultCode:0,ResultDesc:"Callback received; reconciliation required"});}
  return json({ResultCode:0,ResultDesc:"Accepted"});
 }catch(e){console.error("mpesa-callback",e);return json({ResultCode:0,ResultDesc:"Callback received; server reconciliation required"});}
});
