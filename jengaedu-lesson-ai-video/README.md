# JengaEdu AI Lesson Studio

A mobile-friendly lesson planning and video-storyboard module intended to be integrated into the existing JengaEdu school management system.

## Included
- Teacher/administrator sign-in shell using Supabase Auth
- Lesson details form for ECDE, Lower Primary, Upper Primary, Junior School and Senior School
- Editable lesson script and scene storyboard
- Demo lesson generator (works immediately in browser)
- Local draft saving
- Supabase schema with school-scoped RLS starter policies
- Edge Function integration contracts for AI lesson generation and video rendering
- Curriculum record entry with source/version/page metadata

## Important current limitations
This is a functional starter application, not a fully connected production video-generation service. Demo mode generates a sample editable storyboard locally. Real AI script generation requires a compatible AI endpoint. MP4 rendering requires a video-generation/rendering provider that accepts the `render-video` payload and returns a `job_id`. A provider-specific webhook, storage upload and status updater must be implemented for the selected vendor.

No API keys are included. Never place AI or video-provider secrets in `config.js` or browser JavaScript.

## 1. Run the demo
Open `index.html` in a modern browser or serve this folder using any static web server. Click **Try sample lesson**. Enter a grade, learning area and topic first. The demo produces an editable storyboard and can save drafts in that browser.

## 2. Connect Supabase
1. Create or use the JengaEdu Supabase project.
2. Run `supabase/migrations/001_lesson_studio.sql` in the SQL Editor.
3. Add one `lesson_studio_members` row for each authorised teacher/administrator. `school_id` must match the school identifier used in your JengaEdu system. If JengaEdu uses a different user/role schema, adapt this mapping rather than duplicating identities.
4. Put the Supabase project URL and public anon/publishable key in `config.js`.
5. Deploy the Edge Functions.
6. Set the function secrets described below.

Example membership insert (use real UUIDs from your project):
```sql
insert into public.lesson_studio_members(user_id, school_id, role)
values ('AUTH-USER-UUID', 'SCHOOL-UUID', 'teacher');
```

## 3. Configure AI lesson generation
Set Supabase Edge Function secrets:
- `AI_GENERATION_ENDPOINT`
- `AI_GENERATION_API_KEY`

The endpoint receives a JSON request containing `task`, `rules`, `lesson` and `output_schema`. It must return JSON with:
- `title`
- `introduction`
- `explanation`
- `examples`
- `assessment`
- `scenes`: array of `{title, visual, narration}`

The Edge Function passes the signed-in user's access token only for authentication context; the AI provider key stays server-side.

## 4. Configure video rendering and narration
Set:
- `VIDEO_RENDER_ENDPOINT`
- `VIDEO_RENDER_API_KEY`

The render endpoint receives:
```json
{
  "project_id": "uuid",
  "format": "mp4",
  "aspect_ratio": "16:9",
  "language": "en",
  "narration": "text_to_speech",
  "captions": true,
  "details": {},
  "content": {},
  "callback_url": "https://PROJECT.supabase.co/functions/v1/video-render-webhook"
}
```
It must return `{ "job_id": "provider-job-id", "status": "queued" }`.

Before production, implement a provider-specific webhook that:
1. Verifies the provider signature.
2. Confirms the job belongs to the same project/school.
3. Uploads the completed MP4 to a private Supabase Storage bucket.
4. Updates `lesson_video_projects.status` to `ready` and stores a signed-access path or private object path.
5. Handles failed jobs and retries safely.

## 5. Curriculum integrity
Do not pre-fill guessed KICD strands or learning outcomes. Import verified curriculum-design content with source title, version and page reference. Have an authorised administrator verify each record. The teacher should review AI-generated scripts and assessments before classroom use.

## 6. Integrate into JengaEdu
- Add a menu item such as **AI Lesson Studio** in the existing teacher/admin navigation.
- Reuse JengaEdu's existing Supabase Auth session and user IDs if possible.
- Map existing school IDs and roles into `lesson_studio_members`, or modify the policies to use your existing membership tables.
- Embed this module as a route/page in the existing app; do not create a second login system if JengaEdu already has authentication.
- Restrict the route to teachers and administrators.
- Pass teacher class/subject assignments from JengaEdu into the lesson form after reviewing your existing schema.

## 7. Production checklist
- Replace permissive CORS `*` with your JengaEdu allowed origins.
- Review RLS policies against your actual multi-school schema.
- Add rate limits and monthly AI/video quotas per school.
- Add usage/cost estimates before rendering.
- Add private storage access and expiring signed URLs.
- Add provider webhook signature validation.
- Add moderation and safeguarding checks for generated images/narration.
- Test on low-bandwidth Android devices.
- Confirm curriculum source and teacher review before sharing videos with learners.
