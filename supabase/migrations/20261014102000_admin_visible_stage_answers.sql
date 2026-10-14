alter table public.stage_questions add column if not exists answer_text text;
alter table public.stage_questions add column if not exists final_answer_text text;
alter table public.stages add column if not exists answer_text text;
alter table public.stages add column if not exists final_answer_text text;
