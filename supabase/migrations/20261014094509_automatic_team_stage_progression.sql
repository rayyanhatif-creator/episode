-- Progress through stages per team automatically; no supervisor stage-unlock clicks are required.
CREATE OR REPLACE FUNCTION public.get_team_game_state(p_session_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.teams%rowtype; stage_list jsonb; cfg public.game_settings%rowtype; s public.stages%rowtype; target_stage_id uuid;
BEGIN
 IF p_session_token IS NULL OR char_length(p_session_token)<20 THEN
  RETURN jsonb_build_object('success',false,'message','جلسة الفريق غير صالحة. سجّل الدخول برمز الأسرة مرة أخرى.');
 END IF;
 SELECT * INTO t FROM public.teams WHERE session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') AND is_active=true;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); END IF;
 SELECT * INTO cfg FROM public.game_settings WHERE id=true;
 SELECT st.id INTO target_stage_id FROM public.stages st
 WHERE NOT EXISTS(SELECT 1 FROM public.team_stage_assignments a WHERE a.team_id=t.id AND a.stage_id=st.id AND a.completed=true)
 AND NOT EXISTS(SELECT 1 FROM public.answer_submissions olda WHERE olda.team_id=t.id AND olda.stage_id=st.id AND olda.status='accepted')
 ORDER BY st.sort_order LIMIT 1;
 IF target_stage_id IS NOT NULL THEN
  SELECT * INTO s FROM public.stages WHERE id=target_stage_id;
  INSERT INTO public.team_stage_assignments(team_id,stage_id,question_id)
  SELECT t.id,s.id,q.id FROM public.stage_questions q
  LEFT JOIN (SELECT question_id,count(*) AS assigned_count FROM public.team_stage_assignments WHERE stage_id=target_stage_id GROUP BY question_id) ac ON ac.question_id=q.id
  WHERE q.stage_id=target_stage_id ORDER BY coalesce(ac.assigned_count,0),random() LIMIT 1
  ON CONFLICT(team_id,stage_id) DO NOTHING;
 END IF;
 SELECT count(*)::integer INTO t.progress FROM public.team_stage_assignments WHERE team_id=t.id AND completed=true;
 SELECT coalesce(sum(points_awarded),0)::integer INTO t.points FROM public.team_stage_assignments WHERE team_id=t.id AND completed=true;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',st.id,'title',st.title,'number',st.number,'description',st.description,'sort_order',st.sort_order,
  'points_reward',coalesce(q.points_reward,st.points_reward),
  'status',CASE WHEN coalesce(a.completed,false) OR EXISTS(SELECT 1 FROM public.answer_submissions olda WHERE olda.team_id=t.id AND olda.stage_id=st.id AND olda.status='accepted') THEN 'completed' WHEN st.id=target_stage_id THEN 'current' ELSE 'locked' END,
  'prompt',CASE WHEN coalesce(cfg.is_open,false) AND st.id=target_stage_id THEN q.prompt ELSE null END,
  'hint',CASE WHEN coalesce(cfg.is_open,false) AND st.id=target_stage_id AND coalesce(a.hint_unlocked,false) THEN q.hint ELSE null END,
  'hint_unlocked',coalesce(a.hint_unlocked,false) AND coalesce(cfg.is_open,false) AND st.id=target_stage_id,
  'scrambled_sentence',CASE WHEN coalesce(cfg.is_open,false) AND st.id=target_stage_id AND coalesce(a.hint_unlocked,false) THEN q.scrambled_sentence ELSE null END,
  'final_answer_required',coalesce(a.hint_unlocked,false) AND coalesce(cfg.is_open,false) AND st.id=target_stage_id,
  'question_id',q.id
 ) ORDER BY st.sort_order),'[]'::jsonb) INTO stage_list
 FROM public.stages st LEFT JOIN public.team_stage_assignments a ON a.team_id=t.id AND a.stage_id=st.id
 LEFT JOIN public.stage_questions q ON q.id=a.question_id;
 RETURN jsonb_build_object('success',true,'game_open',coalesce(cfg.is_open,false),
  'team',jsonb_build_object('id',t.id,'name',t.name,'points',t.points,'progress',t.progress),'stages',stage_list);
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_stage_answer(p_session_token text,p_stage_id uuid,p_answer text,p_phase text DEFAULT 'riddle')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.teams%rowtype; s public.stages%rowtype; a public.team_stage_assignments%rowtype; q public.stage_questions%rowtype; ok boolean; target_stage_id uuid;
BEGIN
 IF p_phase NOT IN ('riddle','final') THEN RETURN jsonb_build_object('success',false,'message','خطوة إجابة غير صالحة.'); END IF;
 IF p_answer IS NULL OR char_length(trim(p_answer))=0 OR char_length(p_answer)>200 THEN RETURN jsonb_build_object('success',false,'message','اكتب إجابة صالحة.'); END IF;
 SELECT * INTO t FROM public.teams WHERE session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') AND is_active=true FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); END IF;
 IF NOT coalesce((SELECT is_open FROM public.game_settings WHERE id=true),false) THEN RETURN jsonb_build_object('success',false,'message','المشرف أوقف المسابقة مؤقتًا.'); END IF;
 SELECT st.id INTO target_stage_id FROM public.stages st
 WHERE NOT EXISTS(SELECT 1 FROM public.team_stage_assignments aa WHERE aa.team_id=t.id AND aa.stage_id=st.id AND aa.completed=true)
 AND NOT EXISTS(SELECT 1 FROM public.answer_submissions olda WHERE olda.team_id=t.id AND olda.stage_id=st.id AND olda.status='accepted')
 ORDER BY st.sort_order LIMIT 1;
 IF target_stage_id IS NULL OR target_stage_id<>p_stage_id THEN RETURN jsonb_build_object('success',false,'message','أكملوا المرحلة المتاحة أمامكم أولًا.'); END IF;
 SELECT * INTO s FROM public.stages WHERE id=p_stage_id;
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
   RETURN jsonb_build_object('success',true,'correct',true,'phase_complete',true,'points_awarded',q.points_reward,'message','حل صحيح! اكتملت المرحلة وأُضيفت نقاطها إلى رصيدكم. ستنتقلون تلقائيًا إلى المرحلة التالية.');
  END IF;
  RETURN jsonb_build_object('success',true,'correct',false,'phase_complete',false,'message','الحل غير صحيح. راجعوا الكلمات الموجودة على الورقة وحاولوا مرة ثانية.');
 END IF;
END;
$$;