// Supabase Edge Function: render-video
// Configure VIDEO_RENDER_ENDPOINT and VIDEO_RENDER_API_KEY.
// Provider endpoint must accept the documented JSON payload and return { job_id, status }.
// A separate signed webhook should update lesson_video_projects when rendering completes.
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};

serve(async (req) => {
  if (req.method==="OPTIONS") return new Response("ok",{headers:cors});
  try {
    const auth=req.headers.get("Authorization");
    if(!auth) throw new Error("Authentication required");
    const {project_id}=await req.json();
    const url=Deno.env.get("SUPABASE_URL")!;
    const anon=Deno.env.get("SUPABASE_ANON_KEY")!;
    const supabase=createClient(url,anon,{global:{headers:{Authorization:auth}}});
    const {data:project,error}=await supabase.from("lesson_video_projects").select("*").eq("id",project_id).single();
    if(error || !project) throw new Error("Lesson project not found or access denied.");
    const endpoint=Deno.env.get("VIDEO_RENDER_ENDPOINT");
    const key=Deno.env.get("VIDEO_RENDER_API_KEY");
    if(!endpoint || !key) throw new Error("Video rendering provider is not configured. Project is saved; configure VIDEO_RENDER_ENDPOINT and VIDEO_RENDER_API_KEY.");
    const payload={
      project_id,
      format:"mp4",
      aspect_ratio:"16:9",
      language:"en",
      narration:"text_to_speech",
      captions:true,
      details:project.details,
      content:project.content,
      callback_url:`${url}/functions/v1/video-render-webhook`
    };
    const r=await fetch(endpoint,{method:"POST",headers:{"Content-Type":"application/json","Authorization":`Bearer ${key}`},body:JSON.stringify(payload)});
    if(!r.ok) throw new Error(`Video provider error (${r.status}): ${await r.text()}`);
    const result=await r.json();
    await supabase.from("lesson_video_projects").update({status:"queued",provider_job_id:result.job_id}).eq("id",project_id);
    return new Response(JSON.stringify({job_id:result.job_id,status:result.status||"queued"}),{headers:{...cors,"Content-Type":"application/json"}});
  } catch(e) {
    return new Response(JSON.stringify({error:e.message}),{status:400,headers:{...cors,"Content-Type":"application/json"}});
  }
});
