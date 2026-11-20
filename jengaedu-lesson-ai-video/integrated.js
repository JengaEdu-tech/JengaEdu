/* JengaEdu AI Lesson Studio integration.
   Reuses the authenticated JengaEdu Supabase client, active school and membership.
   AI/video provider credentials remain in Supabase Edge Function secrets. */
async function AILessonStudio(){
  const root=document.getElementById("content");
  const role=String(cloudStaffRole||"");
  if(!cloudReady||!cloudUser||!activeSchool?.id){
    root.innerHTML='<div class="card"><h2>🎬 AI Lesson Studio</h2><p>Please sign in to your active JengaEdu school workspace first.</p></div>';return;
  }
  if(!["teacher","school_admin"].includes(role)){
    root.innerHTML='<div class="card"><h2>Access restricted</h2><p>AI Lesson Studio is available to teachers and school administrators.</p></div>';return;
  }
  const style=`<style>
  .ls-wrap{display:grid;gap:16px}.ls-hero{padding:22px;border-radius:18px;color:#fff;background:linear-gradient(115deg,#102a72,#2456d9 65%,#13a9b5)}.ls-hero h2{margin:0 0 7px}.ls-hero p{margin:0;color:#e5efff}.ls-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.ls-field{display:block;font-weight:700;font-size:13px;color:#334155}.ls-field input,.ls-field select,.ls-field textarea{width:100%;margin-top:6px;padding:11px;border:1px solid #dbe3ef;border-radius:9px;font:inherit;background:#fff}.ls-wide{grid-column:1/-1}.ls-actions{display:flex;gap:9px;flex-wrap:wrap;margin-top:14px}.ls-note{padding:12px;border-radius:10px;background:#fff8e8;color:#75551b;font-size:12px;line-height:1.5;margin:12px 0}.ls-scene{border:1px solid #e2e8f0;padding:13px;border-radius:12px;margin:10px 0;background:#fbfdff}.ls-scene label{display:block;font-size:12px;font-weight:700;margin:8px 0}.ls-scene textarea{width:100%;padding:9px;border:1px solid #dbe3ef;border-radius:8px}.ls-status{font-size:13px;color:#64748b;margin-top:10px}.ls-listitem{padding:12px;border:1px solid #e2e8f0;border-radius:10px;margin:8px 0;display:flex;justify-content:space-between;gap:10px;align-items:center}.ls-muted{color:#64748b;font-size:12px}@media(max-width:650px){.ls-grid{grid-template-columns:1fr}.ls-wide{grid-column:auto}}</style>`;
  root.innerHTML=style+`
  <div class="ls-wrap">
    <div class="ls-hero"><div class="small" style="color:#a8fff0;font-weight:800;letter-spacing:1px">JENGAEDU TEACHING & LEARNING</div><h2>🎬 AI Lesson Studio</h2><p>Prepare CBC/CBE-informed lesson scripts, animated scene plans and English narration for your learners.</p></div>
    <div class="card"><div class="toolbar" style="justify-content:space-between"><div><h3 style="margin:0">Create a lesson video</h3><span class="ls-muted">School: ${esc(activeSchool.name||"Your school")} · Signed in as ${esc(role==="school_admin"?"Administrator":"Teacher")}</span></div><button class="light" onclick="lsLoadProjects()">My projects</button></div>
    <div class="ls-grid" style="margin-top:15px">
      <label class="ls-field">Education level<select id="lsLevel"><option>ECDE</option><option>Lower Primary</option><option>Upper Primary</option><option selected>Junior School</option><option>Senior School</option></select></label>
      <label class="ls-field">Grade / class<input id="lsGrade" placeholder="e.g. Grade 7"></label>
      <label class="ls-field">Learning area / subject<input id="lsSubject" placeholder="e.g. Integrated Science"></label>
      <label class="ls-field">Video duration<select id="lsDuration"><option value="3">3 minutes</option><option value="5" selected>5 minutes</option><option value="8">8 minutes</option><option value="10">10 minutes</option><option value="15">15 minutes</option></select></label>
      <label class="ls-field ls-wide">Strand (use verified KICD wording)<input id="lsStrand"></label>
      <label class="ls-field ls-wide">Sub-strand<input id="lsSubstrand"></label>
      <label class="ls-field ls-wide">Specific learning outcome<textarea id="lsOutcome" rows="2" placeholder="Paste the verified learning outcome"></textarea></label>
      <label class="ls-field ls-wide">Lesson topic<input id="lsTopic" placeholder="e.g. Introduction to photosynthesis"></label>
      <label class="ls-field ls-wide">Teacher notes / local examples<textarea id="lsNotes" rows="3"></textarea></label>
    </div>
    <div class="ls-note">Curriculum safeguard: JengaEdu will use the curriculum wording you provide or verified school curriculum records. AI suggestions are drafts and must be checked against the applicable KICD curriculum design before teaching.</div>
    <div class="ls-actions"><button onclick="lsGenerate()" id="lsGenerateBtn">Generate lesson script →</button><button class="light" onclick="lsDemo()">Try sample lesson</button></div><div id="lsStatus" class="ls-status"></div></div>
    <div id="lsEditor" class="card" style="display:none"><h3>Review your storyboard</h3><div id="lsTitle" style="font-weight:800;margin:8px 0 14px"></div>
      <label class="ls-field">Introduction<textarea id="lsIntro" rows="3"></textarea></label>
      <label class="ls-field">Teaching explanation<textarea id="lsExplanation" rows="5"></textarea></label>
      <label class="ls-field">Examples<textarea id="lsExamples" rows="3"></textarea></label>
      <label class="ls-field">Assessment questions<textarea id="lsAssessment" rows="4"></textarea></label>
      <h3>Animated scenes and English narration</h3><div id="lsScenes"></div>
      <div class="ls-actions"><button class="light" onclick="lsSave()">Save draft</button><button onclick="lsRender()">Submit video render job →</button></div><div id="lsRenderStatus" class="ls-status"></div>
    </div><div id="lsProjects" class="card" style="display:none"><h3>My lesson projects</h3><div id="lsProjectList"></div></div>
  </div>`;
  window.__jengaLessonProject=null;
}
function lsVal(id){return (document.getElementById(id)?.value||"").trim()}
function lsEsc(s){return String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}
function lsDetails(){return {level:lsVal("lsLevel"),grade:lsVal("lsGrade"),subject:lsVal("lsSubject"),duration:Number(lsVal("lsDuration")),strand:lsVal("lsStrand"),substrand:lsVal("lsSubstrand"),outcome:lsVal("lsOutcome"),topic:lsVal("lsTopic"),notes:lsVal("lsNotes"),language:"English"}}
function lsSample(f){return {title:`${f.subject}: ${f.topic}`,introduction:`Welcome to this lesson. Today we are learning about ${f.topic}. Think about where you have encountered this idea in everyday life.`,explanation:`Explain ${f.topic} in clear, age-appropriate steps. Introduce important vocabulary, model the concept and connect it to the supplied learning outcome: ${f.outcome||"Teacher to confirm the relevant learning outcome."}`,examples:f.notes||"Use familiar examples from the learners' home, school and local community.",assessment:`1. Explain the main idea of ${f.topic}.\n2. Describe one important term.\n3. Give an everyday example.\n4. Apply the idea to a new situation.`,scenes:[{title:"Welcome",visual:"Bright animated Kenyan classroom title scene; display the topic clearly.",narration:`Welcome to ${f.grade} ${f.subject}. Today we are learning about ${f.topic}.`},{title:"Connect to prior knowledge",visual:"Learners observe a familiar object or situation linked to the topic.",narration:"Think about what you already know. Where have you seen this idea in everyday life?"},{title:"Explain the concept",visual:`Create a clean animated diagram explaining ${f.topic}, with clear labels and simple movement.`,narration:`Let us explore ${f.topic} step by step. Pay attention to the key ideas and how they connect.`},{title:"Worked example",visual:"Teacher guides learners through a relevant, age-appropriate example.",narration:"Now follow this example. Think about why each step makes sense."},{title:"Check understanding",visual:"Show three short questions on screen with thinking time.",narration:"Pause the video and answer these questions in your own words."},{title:"Summary",visual:"Colourful recap of the lesson's main ideas and reflection prompt.",narration:"Remember the main ideas from today's lesson. Think of one way you can use this learning."}]}}
function lsDraw(project){
  window.__jengaLessonProject=project;
  document.getElementById("lsEditor").style.display="block";document.getElementById("lsProjects").style.display="none";
  const c=project.content;document.getElementById("lsTitle").textContent=c.title||"Lesson storyboard";
  for(const [id,k] of [["lsIntro","introduction"],["lsExplanation","explanation"],["lsExamples","examples"],["lsAssessment","assessment"]])document.getElementById(id).value=c[k]||"";
  document.getElementById("lsScenes").innerHTML=(c.scenes||[]).map((s,i)=>`<div class="ls-scene"><b>Scene ${i+1}: ${lsEsc(s.title)}</b><label>Visual direction<textarea data-lsscene="${i}" data-lskey="visual" rows="3">${lsEsc(s.visual)}</textarea></label><label>English narration<textarea data-lsscene="${i}" data-lskey="narration" rows="3">${lsEsc(s.narration)}</textarea></label></div>`).join("");
  document.getElementById("lsEditor").scrollIntoView({behavior:"smooth",block:"start"});
}
function lsCollect(){
  const p=window.__jengaLessonProject;if(!p)return null;
  p.content={...p.content,introduction:lsVal("lsIntro"),explanation:lsVal("lsExplanation"),examples:lsVal("lsExamples"),assessment:lsVal("lsAssessment"),scenes:[...document.querySelectorAll("[data-lsscene]")].reduce((arr,e)=>{let i=Number(e.dataset.lsscene);arr[i]||={};arr[i][e.dataset.lskey]=e.value;return arr;},p.content.scenes||[])};
  return p;
}
async function lsGenerate(){
  const f=lsDetails();const status=document.getElementById("lsStatus");
  if(!f.grade||!f.subject||!f.topic){status.textContent="Enter grade, learning area and topic.";return}
  const btn=document.getElementById("lsGenerateBtn");btn.disabled=true;status.textContent="Generating lesson script…";
  try{
    const {data,error}=await cloud.functions.invoke("generate-lesson",{body:{lesson:f,school_id:activeSchool.id}});
    if(error)throw error;if(data?.error)throw new Error(data.error);
    lsDraw({id:crypto.randomUUID(),school_id:activeSchool.id,teacher_id:cloudUser.id,details:f,content:data,status:"draft"});
    status.textContent="AI lesson created. Review the script and each scene before rendering.";
  }catch(e){status.textContent="AI generation is not configured or failed: "+(e.message||String(e))+". You can use Try sample lesson while setup is completed."}
  finally{btn.disabled=false}
}
function lsDemo(){const f=lsDetails();if(!f.grade||!f.subject||!f.topic){document.getElementById("lsStatus").textContent="Enter grade, learning area and topic first.";return}lsDraw({id:crypto.randomUUID(),school_id:activeSchool.id,teacher_id:cloudUser.id,details:f,content:lsSample(f),status:"draft"});document.getElementById("lsStatus").textContent="Sample storyboard created. This is a demonstration, not AI-generated curriculum content."}
async function lsSave(){
  const p=lsCollect();if(!p)return;const status=document.getElementById("lsRenderStatus");
  const {error}=await cloud.from("lesson_video_projects").upsert({id:p.id,school_id:activeSchool.id,teacher_id:cloudUser.id,details:p.details,content:p.content,status:"draft"});
  status.textContent=error?"Could not save: "+error.message:"Draft saved securely to your JengaEdu school workspace.";
}
async function lsRender(){
  const p=lsCollect();if(!p)return;const status=document.getElementById("lsRenderStatus");
  const {error:saveError}=await cloud.from("lesson_video_projects").upsert({id:p.id,school_id:activeSchool.id,teacher_id:cloudUser.id,details:p.details,content:p.content,status:"draft"});
  if(saveError){status.textContent="Save failed: "+saveError.message;return}
  status.textContent="Submitting video render request…";
  const {data,error}=await cloud.functions.invoke("render-video",{body:{project_id:p.id}});
  if(error||data?.error){status.textContent="Video request not completed: "+(data?.error||error?.message||"Unknown error");return}
  status.textContent=`Video render queued. Job reference: ${data.job_id||"pending"}. The MP4 will appear in project status when the rendering callback is connected.`;
}
async function lsLoadProjects(){
  const panel=document.getElementById("lsProjects"),list=document.getElementById("lsProjectList");
  panel.style.display="block";document.getElementById("lsEditor").style.display="none";list.textContent="Loading projects…";
  const {data,error}=await cloud.from("lesson_video_projects").select("*").eq("school_id",activeSchool.id).order("created_at",{ascending:false}).limit(50);
  if(error){list.textContent="Could not load projects: "+error.message;return}
  list.innerHTML=(data||[]).map(p=>`<div class="ls-listitem"><div><b>${lsEsc(p.content?.title||"Untitled lesson")}</b><div class="ls-muted">${lsEsc(p.details?.grade||"")} · ${lsEsc(p.details?.subject||"")} · ${lsEsc(p.status)}</div></div><button class="light" onclick="lsOpenProject('${p.id}')">Open</button></div>`).join("")||'<p class="ls-muted">No lesson projects saved yet.</p>';
}
async function lsOpenProject(id){
  const {data,error}=await cloud.from("lesson_video_projects").select("*").eq("id",id).eq("school_id",activeSchool.id).single();
  if(error){toast("Could not open lesson project");return}
  lsDraw(data);for(const [id,key] of [["lsLevel","level"],["lsGrade","grade"],["lsSubject","subject"],["lsDuration","duration"],["lsStrand","strand"],["lsSubstrand","substrand"],["lsOutcome","outcome"],["lsTopic","topic"],["lsNotes","notes"]]){const el=document.getElementById(id);if(el)el.value=data.details?.[key]??""}
}
