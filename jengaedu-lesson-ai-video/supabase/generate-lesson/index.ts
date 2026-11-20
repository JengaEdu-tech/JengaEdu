// Supabase Edge Function: generate-lesson
// Configure AI_GENERATION_ENDPOINT and AI_GENERATION_API_KEY as Edge Function secrets.
// Endpoint contract: POST { lesson, output_schema } -> JSON lesson content.
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const auth = req.headers.get("Authorization");
    if (!auth) throw new Error("Authentication required");
    const { lesson } = await req.json();
    if (!lesson?.grade || !lesson?.subject || !lesson?.topic) throw new Error("Grade, learning area and topic are required.");
    if (!["ECDE","Lower Primary","Upper Primary","Junior School","Senior School"].includes(lesson.level)) throw new Error("Unsupported education level.");
    const endpoint = Deno.env.get("AI_GENERATION_ENDPOINT");
    const apiKey = Deno.env.get("AI_GENERATION_API_KEY");
    if (!endpoint || !apiKey) throw new Error("AI lesson provider is not configured. Add AI_GENERATION_ENDPOINT and AI_GENERATION_API_KEY.");
    const prompt = {
      task: "Create an editable English-only classroom lesson script and animated storyboard for a Kenyan CBC/CBE teacher.",
      rules: [
        "Treat the teacher-provided strand, sub-strand and learning outcome as supplied curriculum source text.",
        "Never invent or claim official KICD strands, sub-strands, outcomes or assessment requirements.",
        "If curriculum fields are blank, clearly mark curriculum alignment as teacher verification required.",
        "Use age-appropriate, accurate explanations and Kenyan classroom examples where relevant.",
        "Return six to eight scenes, each with a visual direction and narration.",
        "Return valid JSON only; no markdown."
      ],
      lesson,
      output_schema: {
        title:"string", introduction:"string", explanation:"string", examples:"string", assessment:"string",
        curriculum_verification:"string",
        scenes:[{title:"string",visual:"string",narration:"string"}]
      }
    };
    const response = await fetch(endpoint, {
      method:"POST",
      headers:{"Content-Type":"application/json","Authorization":`Bearer ${apiKey}`},
      body:JSON.stringify(prompt)
    });
    if (!response.ok) throw new Error(`AI provider error (${response.status}): ${await response.text()}`);
    const data = await response.json();
    return new Response(JSON.stringify(data), {headers:{...cors,"Content-Type":"application/json"}});
  } catch (e) {
    return new Response(JSON.stringify({error:e.message}), {status:400,headers:{...cors,"Content-Type":"application/json"}});
  }
});
