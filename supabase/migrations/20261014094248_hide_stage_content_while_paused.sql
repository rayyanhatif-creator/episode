-- Do not send current-stage prompts or hints to clients while the supervisor has paused the competition.
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
  'prompt',CASE WHEN coalesce(cfg.is_open,false) AND s.status='current' AND NOT coalesce(a.completed,false) THEN q.prompt ELSE null END,
  'hint',CASE WHEN coalesce(cfg.is_open,false) AND s.status='current' AND coalesce(a.hint_unlocked,false) THEN q.hint ELSE null END,
  'hint_unlocked',coalesce(a.hint_unlocked,false) AND coalesce(cfg.is_open,false),
  'scrambled_sentence',CASE WHEN coalesce(cfg.is_open,false) AND s.status='current' AND coalesce(a.hint_unlocked,false) THEN q.scrambled_sentence ELSE null END,
  'final_answer_required',coalesce(a.hint_unlocked,false) AND coalesce(cfg.is_open,false),
  'question_id',q.id
 ) ORDER BY s.sort_order),'[]'::jsonb) INTO stage_list
 FROM public.stages s LEFT JOIN public.team_stage_assignments a ON a.team_id=t.id AND a.stage_id=s.id
 LEFT JOIN public.stage_questions q ON q.id=a.question_id;
 RETURN jsonb_build_object('success',true,'game_open',coalesce(cfg.is_open,false),
  'team',jsonb_build_object('id',t.id,'name',t.name,'points',t.points,'progress',t.progress),'stages',stage_list);
END;
$$;