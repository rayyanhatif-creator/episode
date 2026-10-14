CREATE TABLE IF NOT EXISTS public.stage_questions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stage_id uuid NOT NULL REFERENCES public.stages(id) ON DELETE CASCADE,
  variant_no integer NOT NULL CHECK (variant_no BETWEEN 1 AND 3),
  prompt text NOT NULL,
  answer_hash text NOT NULL,
  hint text NOT NULL DEFAULT '',
  scrambled_sentence text NOT NULL DEFAULT '',
  final_answer_hash text NOT NULL,
  points_reward integer NOT NULL DEFAULT 100 CHECK (points_reward BETWEEN 0 AND 10000),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(stage_id, variant_no)
);
CREATE TABLE IF NOT EXISTS public.team_stage_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id uuid NOT NULL REFERENCES public.teams(id) ON DELETE CASCADE,
  stage_id uuid NOT NULL REFERENCES public.stages(id) ON DELETE CASCADE,
  question_id uuid NOT NULL REFERENCES public.stage_questions(id) ON DELETE CASCADE,
  hint_unlocked boolean NOT NULL DEFAULT false,
  completed boolean NOT NULL DEFAULT false,
  points_awarded integer NOT NULL DEFAULT 0 CHECK (points_awarded >= 0),
  assigned_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  UNIQUE(team_id, stage_id)
);
ALTER TABLE public.stage_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_stage_assignments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin manages stage questions" ON public.stage_questions;
CREATE POLICY "admin manages stage questions" ON public.stage_questions FOR ALL TO authenticated USING (public.is_game_admin()) WITH CHECK (public.is_game_admin());
DROP POLICY IF EXISTS "admin reads team stage assignments" ON public.team_stage_assignments;
CREATE POLICY "admin reads team stage assignments" ON public.team_stage_assignments FOR SELECT TO authenticated USING (public.is_game_admin());
GRANT SELECT, INSERT, UPDATE, DELETE ON public.stage_questions TO authenticated;
GRANT SELECT ON public.team_stage_assignments TO authenticated;

INSERT INTO public.stage_questions(stage_id, variant_no, prompt, answer_hash, hint, scrambled_sentence, final_answer_hash, points_reward)
SELECT s.id, v.variant_no, s.prompt, s.answer_hash, coalesce(s.hint,''), coalesce(s.scrambled_sentence,''), s.answer_hash, s.points_reward
FROM public.stages s CROSS JOIN (VALUES (1),(2),(3)) AS v(variant_no)
ON CONFLICT (stage_id, variant_no) DO NOTHING;

INSERT INTO public.team_stage_assignments(team_id, stage_id, question_id, hint_unlocked, completed, points_awarded, completed_at)
SELECT a.team_id, a.stage_id, q.id, true, true, s.points_reward, coalesce(a.submitted_at,now())
FROM public.answer_submissions a
JOIN public.stages s ON s.id=a.stage_id
JOIN public.stage_questions q ON q.stage_id=s.id AND q.variant_no=1
WHERE a.status='accepted'
ON CONFLICT (team_id,stage_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.join_game(p_team_name text,p_session_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cfg public.game_settings%rowtype; tok text; t public.teams%rowtype; fc public.family_codes%rowtype;
BEGIN
 SELECT * INTO cfg FROM public.game_settings WHERE id=true;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','إعدادات المسابقة غير جاهزة.'); END IF;
 SELECT * INTO fc FROM public.family_codes
 WHERE code_hash=encode(extensions.digest(lower(trim(p_session_code)),'sha256'),'hex')
 AND is_active=true
 AND (used_by_team IS NULL OR EXISTS (SELECT 1 FROM public.teams existing_team WHERE existing_team.id=public.family_codes.used_by_team AND existing_team.name=trim(p_team_name)))
 FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','رمز الأسرة غير صحيح أو سبق استخدامه. اطلب رمزًا جديدًا من المشرف.'); END IF;
 IF char_length(trim(p_team_name)) NOT BETWEEN 2 AND 50 THEN RETURN jsonb_build_object('success',false,'message','اسم الفريق يجب أن يكون بين حرفين و50 حرفًا.'); END IF;
 tok:=encode(extensions.gen_random_bytes(32),'hex');
 IF fc.used_by_team IS NULL THEN
  INSERT INTO public.teams(name,session_token_hash) VALUES(trim(p_team_name),encode(extensions.digest(tok,'sha256'),'hex')) RETURNING * INTO t;
  UPDATE public.family_codes SET used_by_team=t.id,used_at=now() WHERE id=fc.id;
 ELSE
  UPDATE public.teams SET session_token_hash=encode(extensions.digest(tok,'sha256'),'hex') WHERE id=fc.used_by_team AND name=trim(p_team_name) RETURNING * INTO t;
 END IF;
 INSERT INTO public.audit_logs(action,entity_type,entity_id,details) VALUES('team_joined','team',t.id::text,jsonb_build_object('team_name',t.name,'family_name',fc.family_name));
 RETURN jsonb_build_object('success',true,'team_id',t.id,'team_name',t.name,'session_token',tok);
EXCEPTION WHEN unique_violation THEN RETURN jsonb_build_object('success',false,'message','اسم الفريق مستخدم بالفعل. اختر اسمًا آخر.');
END;
$$;

CREATE OR REPLACE FUNCTION public.get_team_game_state(p_session_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.teams%rowtype; stage_list jsonb; cfg public.game_settings%rowtype; s public.stages%rowtype;
BEGIN
 IF p_session_token IS NULL OR char_length(p_session_token)<20 THEN
  RETURN jsonb_build_object('success',false,'message','جلسة الفريق غير صالحة. سجّل الدخول برمز الأسرة مرة أخرى.');
 END IF;
 SELECT * INTO t FROM public.teams WHERE session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') AND is_active=true;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); END IF;
 SELECT * INTO cfg FROM public.game_settings WHERE id=true;
 FOR s IN SELECT * FROM public.stages ORDER BY sort_order LOOP
  IF s.status='current' THEN
   INSERT INTO public.team_stage_assignments(team_id,stage_id,question_id)
   SELECT t.id,s.id,q.id FROM public.stage_questions q
   LEFT JOIN (SELECT question_id,count(*) AS assigned_count FROM public.team_stage_assignments WHERE stage_id=s.id GROUP BY question_id) ac ON ac.question_id=q.id
   WHERE q.stage_id=s.id ORDER BY coalesce(ac.assigned_count,0),random() LIMIT 1
   ON CONFLICT(team_id,stage_id) DO NOTHING;
  END IF;
 END LOOP;
 SELECT count(*)::integer INTO t.progress FROM public.team_stage_assignments WHERE team_id=t.id AND completed=true;
 SELECT coalesce(sum(points_awarded),0)::integer INTO t.points FROM public.team_stage_assignments WHERE team_id=t.id AND completed=true;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',s.id,'title',s.title,'number',s.number,'description',s.description,'sort_order',s.sort_order,
  'points_reward',coalesce(q.points_reward,s.points_reward),
  'status',CASE WHEN coalesce(a.completed,false) OR EXISTS(SELECT 1 FROM public.answer_submissions olda WHERE olda.team_id=t.id AND olda.stage_id=s.id AND olda.status='accepted') THEN 'completed' WHEN s.status='current' THEN 'current' ELSE 'locked' END,
  'prompt',CASE WHEN s.status='current' AND NOT coalesce(a.completed,false) THEN q.prompt ELSE null END,
  'hint',CASE WHEN s.status='current' AND coalesce(a.hint_unlocked,false) THEN q.hint ELSE null END,
  'hint_unlocked',coalesce(a.hint_unlocked,false),
  'scrambled_sentence',CASE WHEN s.status='current' AND coalesce(a.hint_unlocked,false) THEN q.scrambled_sentence ELSE null END,
  'final_answer_required',coalesce(a.hint_unlocked,false),
  'question_id',q.id
 ) ORDER BY s.sort_order),'[]'::jsonb) INTO stage_list
 FROM public.stages s LEFT JOIN public.team_stage_assignments a ON a.team_id=t.id AND a.stage_id=s.id
 LEFT JOIN public.stage_questions q ON q.id=a.question_id;
 RETURN jsonb_build_object('success',true,'game_open',coalesce(cfg.is_open,false),
  'team',jsonb_build_object('id',t.id,'name',t.name,'points',t.points,'progress',t.progress),'stages',stage_list);
END;
$$;

DROP FUNCTION IF EXISTS public.submit_stage_answer(text,uuid,text);
CREATE OR REPLACE FUNCTION public.submit_stage_answer(p_session_token text,p_stage_id uuid,p_answer text,p_phase text DEFAULT 'riddle')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.teams%rowtype; s public.stages%rowtype; a public.team_stage_assignments%rowtype; q public.stage_questions%rowtype; ok boolean;
BEGIN
 IF p_phase NOT IN ('riddle','final') THEN RETURN jsonb_build_object('success',false,'message','خطوة إجابة غير صالحة.'); END IF;
 IF p_answer IS NULL OR char_length(trim(p_answer))=0 OR char_length(p_answer)>200 THEN RETURN jsonb_build_object('success',false,'message','اكتب إجابة صالحة.'); END IF;
 SELECT * INTO t FROM public.teams WHERE session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') AND is_active=true FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); END IF;
 IF NOT coalesce((SELECT is_open FROM public.game_settings WHERE id=true),false) THEN RETURN jsonb_build_object('success',false,'message','المشرف أوقف المسابقة مؤقتًا.'); END IF;
 SELECT * INTO s FROM public.stages WHERE id=p_stage_id;
 IF NOT FOUND OR s.status<>'current' THEN RETURN jsonb_build_object('success',false,'message','هذه المرحلة مقفلة حاليًا من المشرف.'); END IF;
 SELECT * INTO a FROM public.team_stage_assignments WHERE team_id=t.id AND stage_id=s.id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','تعذر تجهيز سؤال فريقكم. حدّثوا الصفحة وحاولوا مجددًا.'); END IF;
 IF a.completed THEN RETURN jsonb_build_object('success',true,'correct',true,'phase_complete',true,'message','أنجزتم هذه المرحلة سابقًا، ونقاطها محفوظة.'); END IF;
 SELECT * INTO q FROM public.stage_questions WHERE id=a.question_id;
 IF p_phase='riddle' THEN
  IF a.hint_unlocked THEN RETURN jsonb_build_object('success',false,'message','لقد فتحتم التلميح بالفعل. أكملوا حل الورقة.'); END IF;
  ok:=encode(extensions.digest(lower(trim(p_answer)),'sha256'),'hex')=q.answer_hash;
  INSERT INTO public.answer_submissions(team_id,stage_id,answer_text,is_correct,status) VALUES(t.id,s.id,trim(p_answer),ok,CASE WHEN ok THEN 'pending' ELSE 'rejected' END);
  IF ok THEN UPDATE public.team_stage_assignments SET hint_unlocked=true WHERE id=a.id;
   RETURN jsonb_build_object('success',true,'correct',true,'phase_complete',false,'hint_unlocked',true,'message','إجابة صحيحة! ظهر لكم التلميح؛ ابحثوا عن الورقة واكتبوا الحل النهائي.');
  END IF;
  RETURN jsonb_build_object('success',true,'correct',false,'phase_complete',false,'message','الإجابة غير صحيحة. حاولوا مرة ثانية.');
 ELSE
  IF NOT a.hint_unlocked THEN RETURN jsonb_build_object('success',false,'message','حلّوا السؤال أولًا لفتح التلميح.'); END IF;
  ok:=encode(extensions.digest(lower(trim(p_answer)),'sha256'),'hex')=q.final_answer_hash;
  INSERT INTO public.answer_submissions(team_id,stage_id,answer_text,is_correct,status) VALUES(t.id,s.id,trim(p_answer),ok,CASE WHEN ok THEN 'accepted' ELSE 'rejected' END);
  IF ok THEN
   UPDATE public.team_stage_assignments SET completed=true,points_awarded=q.points_reward,completed_at=now() WHERE id=a.id;
   UPDATE public.teams SET points=points+q.points_reward,progress=progress+1 WHERE id=t.id;
   INSERT INTO public.audit_logs(action,entity_type,entity_id,details) VALUES('stage_completed','stage',s.id::text,jsonb_build_object('team_id',t.id,'question_id',q.id,'points',q.points_reward));
   RETURN jsonb_build_object('success',true,'correct',true,'phase_complete',true,'points_awarded',q.points_reward,'message','حل صحيح! اكتملت المرحلة وأُضيفت نقاطها إلى رصيدكم.');
  END IF;
  RETURN jsonb_build_object('success',true,'correct',false,'phase_complete',false,'message','الحل غير صحيح. راجعوا الكلمات الموجودة على الورقة وحاولوا مرة ثانية.');
 END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.join_game(text,text) FROM public;
REVOKE ALL ON FUNCTION public.get_team_game_state(text) FROM public;
REVOKE ALL ON FUNCTION public.submit_stage_answer(text,uuid,text,text) FROM public;
GRANT EXECUTE ON FUNCTION public.join_game(text,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_team_game_state(text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.submit_stage_answer(text,uuid,text,text) TO anon,authenticated;
