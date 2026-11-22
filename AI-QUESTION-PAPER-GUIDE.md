# JengaEdu AI Question Paper Generator — Phase 5

Teachers can generate structured draft assessments for Kenya CBC/CBE using teacher-supplied strands, sub-strands and learning outcomes.

## Workflow
1. Open **AI Question Papers**.
2. Enter title, class, subject, term/year, strands and the relevant learning outcomes.
3. Select **Generate AI draft**.
4. Review all questions, expected answers, marks and curriculum alignment.
5. Edit and approve the paper before printing or issuing.

## Security
Generation runs through `supabase/functions/generate-ai-question-paper`. The function checks the signed-in Supabase user and active school membership role. The OpenAI API key is stored as a Supabase Edge Function secret (`OPENAI_API_KEY`) and is never sent to the browser. Set `OPENAI_MODEL` optionally; default is `gpt-4.1-mini`.

## Curriculum accuracy
The model uses the curriculum strands and outcomes entered by the teacher. It must not invent official KICD codes or claim official approval. AI output is a draft and requires professional teacher review.

## Deploy
```bash
supabase functions deploy generate-ai-question-paper
supabase secrets set OPENAI_API_KEY=YOUR_PRIVATE_OPENAI_API_KEY
supabase secrets set OPENAI_MODEL=gpt-4.1-mini
```
