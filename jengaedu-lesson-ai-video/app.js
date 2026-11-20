(() => {
  const cfg = window.JENGAEDU_CONFIG || {};
  const hasSupabase = !!(cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY && window.supabase);
  const db = hasSupabase ? window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;
  let currentUser = null, currentRole = "teacher", currentSchoolId = null, activeProject = null;
  let projects = JSON.parse(localStorage.getItem("jenga_lesson_projects") || "[]");
  let curriculum = JSON.parse(localStorage.getItem("jenga_curriculum_records") || "[]");
  const $ = id => document.getElementById(id);
  const val = id => $(id).value.trim();
  const setStatus = (id, msg, error=false) => { $(id).textContent = msg; $(id).style.color = error ? "#b42318" : "#68758d"; };
  const show = id => $(id).classList.remove("hidden");
  const hide = id => $(id).classList.add("hidden");
  const fields = () => ({
    level:val("level"), grade:val("grade"), subject:val("subject"), duration:Number(val("duration")),
    strand:val("strand"), substrand:val("substrand"), outcome:val("outcome"), topic:val("topic"), notes:val("notes"), language:"English"
  });
  function switchPanel(id) {
    ["editorPanel","projectsPanel","curriculumPanel"].forEach(hide);
    if(id) show(id);
  }
  function sampleLesson(f) {
    const topic = f.topic || "Introduction to the topic";
    return {
      title: `${f.subject}: ${topic}`,
      introduction: `Welcome. In this lesson, we will explore ${topic}. Think about what you already know and where you have seen this idea in everyday life.`,
      explanation: `Begin by introducing the key idea of ${topic} in clear, age-appropriate language. Explain important vocabulary one term at a time. Model the concept using a simple example, pause to check understanding, and connect the explanation to the stated learning outcome: ${f.outcome || "the teacher's verified learning outcome"}.`,
      examples: f.notes || `Use familiar examples from the learners' home, school and local community. Ask learners to describe another example and explain their reasoning.`,
      assessment: `1. What is the main idea of ${topic}?\n2. Explain one important term from the lesson.\n3. Give one example from everyday life.\n4. Apply what you have learned to a new situation.\n5. What question would you still like to ask?`,
      scenes: [
        {title:"Welcome and lesson question",visual:`Animated classroom title card introducing ${topic}. Show a welcoming Kenyan classroom and the lesson question.`,narration:`Welcome to this ${f.grade} ${f.subject} lesson. Today we are learning about ${topic}.`},
        {title:"Connect to prior knowledge",visual:"Show learners observing a familiar real-life object or situation connected to the topic.",narration:"Before we begin, think about what you already know. Where have you seen this idea in everyday life?"},
        {title:"Explain the key concept",visual:`Use a clean animated diagram to explain ${topic}. Label each important part clearly and avoid clutter.`,narration:`Let us understand the main idea. ${topic} can be explained step by step. Pay attention to the key terms and how they connect.`},
        {title:"Worked example",visual:"Show a teacher guiding learners through a simple age-appropriate example with clear visual steps.",narration:"Now let us look at an example. Follow each step and think about why it makes sense."},
        {title:"Check understanding",visual:"Display three short on-screen questions with time for learners to think.",narration:"Pause and answer these questions. Explain your thinking, not just your final answer."},
        {title:"Summary and reflection",visual:"Show a visual recap of the key ideas and a simple reflection prompt.",narration:"To conclude, remember the main ideas from today's lesson. Think of one way you can use this learning outside the classroom."}
      ]
    };
  }
  function renderScenes(scenes) {
    $("sceneList").innerHTML = "";
    scenes.forEach((s,i) => {
      const div = document.createElement("div"); div.className="scene";
      div.innerHTML = `<div class="scene-top"><b>Scene ${i+1}: ${escapeHtml(s.title || "")}</b><small>Animated visual + narration</small></div><label>Visual direction<textarea data-scene="${i}" data-key="visual">${escapeHtml(s.visual || "")}</textarea></label><label>Narration<textarea data-scene="${i}" data-key="narration">${escapeHtml(s.narration || "")}</textarea></label>`;
      $("sceneList").appendChild(div);
    });
  }
  function escapeHtml(s){return String(s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));}
  function readScenes(){return [...$("sceneList").querySelectorAll("textarea")].reduce((a,e)=>{const i=Number(e.dataset.scene);a[i] ||= {};a[i][e.dataset.key]=e.value;return a;},[]);}
  function openEditor(project){
    activeProject=project; $("lessonTitle").textContent=project.content.title;
    $("intro").value=project.content.introduction; $("explanation").value=project.content.explanation;
    $("examples").value=project.content.examples; $("assessment").value=project.content.assessment;
    renderScenes(project.content.scenes || []); switchPanel("editorPanel");
  }
  function collectProject(){
    const f=fields();
    return {id:activeProject?.id || crypto.randomUUID(),created_at:activeProject?.created_at || new Date().toISOString(),
      teacher_id:currentUser?.id || null, school_id:currentSchoolId, details:f, content:{
        title:$("lessonTitle").textContent, introduction:val("intro"), explanation:val("explanation"),
        examples:val("examples"), assessment:val("assessment"), scenes:readScenes()
      }, status:"draft"};
  }
  async function persist(p){
    const ix=projects.findIndex(x=>x.id===p.id); if(ix>=0) projects[ix]=p; else projects.unshift(p);
    localStorage.setItem("jenga_lesson_projects",JSON.stringify(projects));
    if(db && currentUser){
      const {error}=await db.from("lesson_video_projects").upsert({id:p.id,teacher_id:currentUser.id,school_id:currentSchoolId,details:p.details,content:p.content,status:p.status});
      if(error) console.warn("Cloud save failed",error.message);
    }
  }
  async function generate(useDemo=false){
    const f=fields();
    if(!f.topic || !f.subject || !f.grade){setStatus("generateStatus","Enter grade, learning area and lesson topic first.",true);return;}
    $("generateBtn").disabled=true; setStatus("generateStatus","Preparing lesson script and storyboard…");
    try{
      let content;
      if(!useDemo && db && currentUser){
        const {data:{session}}=await db.auth.getSession();
        const resp=await fetch(`${cfg.SUPABASE_URL}/functions/v1/generate-lesson`,{
          method:"POST",headers:{ "Content-Type":"application/json","Authorization":`Bearer ${session.access_token}`,"apikey":cfg.SUPABASE_ANON_KEY },
          body:JSON.stringify({lesson:f})
        });
        if(!resp.ok) throw new Error((await resp.text()) || "AI lesson service failed");
        content=await resp.json();
      } else {
        content=sampleLesson(f);
        setStatus("generateStatus","Demo lesson created. Connect Supabase and configure the AI service for AI-generated content.");
      }
      activeProject={id:crypto.randomUUID(),created_at:new Date().toISOString(),details:f,content,status:"draft"};
      openEditor(activeProject);
      if(useDemo || !db) setStatus("generateStatus",""); else setStatus("generateStatus","Lesson generated. Review and edit every section before rendering.");
    }catch(e){setStatus("generateStatus",e.message,true);}
    finally{$("generateBtn").disabled=false;}
  }
  function showProjects(){
    switchPanel("projectsPanel"); $("projectList").innerHTML="";
    if(!projects.length){$("projectList").textContent="No saved projects yet.";return;}
    projects.forEach(p=>{const d=document.createElement("div");d.className="project-card";d.innerHTML=`<div><b>${escapeHtml(p.content.title)}</b><p>${escapeHtml(p.details.grade)} · ${escapeHtml(p.details.subject)} · ${new Date(p.created_at).toLocaleDateString()}</p></div><button class="secondary">Open</button>`;d.querySelector("button").onclick=()=>openEditor(p);$("projectList").appendChild(d);});
  }
  async function signIn(){
    if(!db){setStatus("authStatus","Supabase is not configured. Demo mode works without signing in.");return;}
    const {data,error}=await db.auth.signInWithPassword({email:val("email"),password:val("password")});
    if(error){setStatus("authStatus",error.message,true);return;}
    currentUser=data.user; await loadRole(); $("signOutBtn").classList.remove("hidden");
    $("connectionText").textContent="Connected to school workspace";$("connectionDot").style.background="#19a879";
    setStatus("authStatus",`Signed in as ${currentRole}.`);
  }
  async function loadRole(){
    const {data,error}=await db.from("lesson_studio_members").select("role,school_id").eq("user_id",currentUser.id).maybeSingle();
    if(error || !data || !["teacher","administrator"].includes(data.role)){await db.auth.signOut();currentUser=null;throw new Error("Your account is not authorised for Lesson Studio. Ask your JengaEdu administrator.");}
    currentRole=data.role;
  }
  async function signOut(){if(db) await db.auth.signOut();currentUser=null;$("signOutBtn").classList.add("hidden");setStatus("authStatus","Signed out.");}
  async function renderVideo(){
    const p=collectProject(); await persist(p);
    setStatus("renderStatus","Saved. Video rendering requires a configured animation/video provider and text-to-speech provider. Your storyboard is ready to send to that service.");
    if(db && currentUser){
      const {data:{session}}=await db.auth.getSession();
      try{
        const r=await fetch(`${cfg.SUPABASE_URL}/functions/v1/render-video`,{method:"POST",headers:{"Content-Type":"application/json","Authorization":`Bearer ${session.access_token}`,"apikey":cfg.SUPABASE_ANON_KEY},body:JSON.stringify({project_id:p.id})});
        const j=await r.json(); if(!r.ok) throw new Error(j.error || "Render request failed");
        setStatus("renderStatus",`Video job submitted. Job ID: ${j.job_id || "pending"}. Check My lesson projects for status.`);
      }catch(e){setStatus("renderStatus",e.message,true);}
    } else {
      setStatus("renderStatus","Project saved in this browser. Connect Supabase and configure video + narration providers to export a real MP4.");
    }
  }
  function addCurriculum(){
    try{const rec=JSON.parse(val("curriculumJson"));if(!rec.level||!rec.grade||!rec.learning_area||!rec.strand||!rec.source)throw new Error("Include level, grade, learning_area, strand and source.");curriculum.push(rec);localStorage.setItem("jenga_curriculum_records",JSON.stringify(curriculum));setStatus("curriculumStatus","Curriculum record saved locally. Connect Supabase to share it securely with your school.");$("curriculumJson").value="";renderCurriculum();}
    catch(e){setStatus("curriculumStatus",e.message,true);}
  }
  function renderCurriculum(){$("curriculumList").innerHTML="";curriculum.forEach(r=>{const d=document.createElement("div");d.className="project-card";d.textContent=`${r.level} · ${r.grade} · ${r.learning_area} · ${r.strand} (${r.source})`;$("curriculumList").appendChild(d);});}
  $("generateBtn").onclick=()=>generate(false);$("demoBtn").onclick=()=>generate(true);$("saveBtn").onclick=async()=>{await persist(collectProject());setStatus("renderStatus","Project saved.");};
  $("renderBtn").onclick=renderVideo;$("signInBtn").onclick=()=>signIn().catch(e=>setStatus("authStatus",e.message,true));$("signOutBtn").onclick=signOut;
  $("savedNav").onclick=showProjects;$("backBtn").onclick=()=>switchPanel(null);$("curriculumNav").onclick=()=>{switchPanel("curriculumPanel");renderCurriculum();};$("addCurriculumBtn").onclick=addCurriculum;
  if(hasSupabase){$("connectionText").textContent="Supabase configured";$("connectionDot").style.background="#19a879";db.auth.getSession().then(({data})=>{if(data.session){currentUser=data.session.user;loadRole().catch(e=>setStatus("authStatus",e.message,true));}});}
  else {$("authStatus").textContent="Demo mode is ready. Configure config.js and Supabase to enable school accounts, cloud saving and AI/video services.";}
})();