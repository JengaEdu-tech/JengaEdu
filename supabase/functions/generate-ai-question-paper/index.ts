import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:{...cors,"Content-Type":"application/json"}});
const env=(k:string)=>Deno.env.get(k)||"";
serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return json({error:"POST required"},405);
 try{
  const token=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
  if(!token)return json({error:"Sign in is required"},401);
  const url=env("SUPABASE_URL"),anon=env("SUPABASE_ANON_KEY"),key=env("OPENAI_API_KEY");
  if(!url||!anon||!key)return json({error:"Configure Supabase function environment and OPENAI_API_KEY"},500);
  const auth=await fetch(`${url}/auth/v1/user`,{headers:{apikey:anon,Authorization:`Bearer ${token}`}});
  if(!auth.ok)return json({error:"Your session is invalid"},401);
  const user=await auth.json(),body=await req.json();
  const schoolId=String(body.schoolId||"");
  if(!/^[0-9a-f-]{36}$/i.test(schoolId))return json({error:"A valid school is required"},400);
  const m=await fetch(`${url}/rest/v1/school_memberships?user_id=eq.${encodeURIComponent(user.id)}&school_id=eq.${encodeURIComponent(schoolId)}&status=eq.active&select=role`,{headers:{apikey:anon,Authorization:`Bearer ${token}`}});
  if(!m.ok)return json({error:"Could not verify school membership"},403);
  const members=await m.json(),allowed=["school_admin","headteacher","deputy_headteacher","teacher"];
  if(!members.some((x:any)=>allowed.includes(x.role)))return json({error:"Teacher or school academic administrator permission required"},403);
  const required=["title","className","subject","strands","outcomes"];
  if(required.some(k=>!String(body[k]||"").trim()))return json({error:"Provide title, class, subject, strands and curriculum learning outcomes"},400);
  const count=Math.max(5,Math.min(40,Number(body.questionCount)||15));
  const prompt=`Create a teacher-reviewable Kenya CBC/CBE assessment paper. Use only the curriculum strands, sub-strands and learning outcomes supplied; do not invent curriculum codes or claim official KICD approval. Every item must assess an application of learning in a realistic Kenyan school, home, community, agriculture, enterprise, environment, design or problem-solving context. Avoid repeating items. Return JSON only with keys: instructions (string), duration_minutes (integer), total_marks (integer), questions (array of {number,question,context,marks,expected_answer,learning_outcome}). Make exactly ${count} questions. Ensure marks sum to total_marks. Do not include answer key in learner-facing questions; put concise expected_answer separately for teacher review.
School/class: ${String(body.className).slice(0,80)}
Subject: ${String(body.subject).slice(0,80)}
Term/year: ${String(body.term||"").slice(0,40)} / ${String(body.year||"").slice(0,10)}
Strands and sub-strands: ${String(body.strands).slice(0,3000)}
Learning outcomes / curriculum notes: ${String(body.outcomes).slice(0,5000)}
Teacher instructions: ${String(body.teacherInstructions||"").slice(0,1000)}`;
  const response=await fetch("https://api.openai.com/v1/chat/completions",{method:"POST",headers:{Authorization:`Bearer ${key}`,"Content-Type":"application/json"},body:JSON.stringify({model:env("OPENAI_MODEL")||"gpt-4.1-mini",temperature:0.4,response_format:{type:"json_object"},messages:[{role:"system",content:"You are an assessment drafting assistant. Be accurate, age-appropriate and transparent. Output valid JSON only."},{role:"user",content:prompt}]})});
  const raw=await response.json();if(!response.ok)return json({error:raw?.error?.message||"AI provider request failed"},502);
  let paper;try{paper=JSON.parse(raw.choices?.[0]?.message?.content||"{}")}catch{return json({error:"AI response was not valid JSON"},502)}
  if(!Array.isArray(paper.questions)||paper.questions.length!==count)return json({error:"AI returned an incomplete paper. Try again or reduce the question count."},502);
  return json({paper,model:env("OPENAI_MODEL")||"gpt-4.1-mini",review_required:true});
 }catch(e){return json({error:String(e?.message||e)},500)}
});
