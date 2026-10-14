ALTER TABLE public.stages
  ADD COLUMN IF NOT EXISTS scrambled_sentence text;

CREATE OR REPLACE FUNCTION public.get_team_game_state(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  t public.teams%rowtype;
  stage_list jsonb;
BEGIN
  IF p_session_token IS NULL OR char_length(p_session_token) < 20 THEN
    RETURN jsonb_build_object('success', false, 'message', 'جلسة الفريق غير صالحة. سجّل الدخول برمز الأسرة مرة أخرى.');
  END IF;
  SELECT * INTO t FROM public.teams
  WHERE session_token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex') AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'انتهت جلسة الفريق. سجّل الدخول برمز الأسرة مرة أخرى.');
  END IF;
  SELECT count(DISTINCT stage_id)::integer INTO t.progress FROM public.answer_submissions
  WHERE team_id = t.id AND status = 'accepted';
  SELECT coalesce(sum(s.points_reward), 0)::integer INTO t.points FROM public.stages s
  WHERE EXISTS (SELECT 1 FROM public.answer_submissions a WHERE a.team_id = t.id AND a.stage_id = s.id AND a.status = 'accepted');
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'title', s.title, 'number', s.number, 'description', s.description,
    'sort_order', s.sort_order, 'points_reward', s.points_reward,
    'status', CASE
      WHEN EXISTS (SELECT 1 FROM public.answer_submissions a WHERE a.team_id = t.id AND a.stage_id = s.id AND a.status = 'accepted') THEN 'completed'
      WHEN s.status = 'current' THEN 'current' ELSE 'locked' END,
    'prompt', CASE WHEN s.status = 'current' THEN s.prompt ELSE null END,
    'hint', CASE WHEN s.status = 'current' THEN s.hint ELSE null END,
    'scrambled_sentence', CASE WHEN s.status = 'current' THEN s.scrambled_sentence ELSE null END
  ) ORDER BY s.sort_order), '[]'::jsonb) INTO stage_list FROM public.stages s;
  RETURN jsonb_build_object('success', true,
    'team', jsonb_build_object('id', t.id, 'name', t.name, 'points', t.points, 'progress', t.progress),
    'stages', stage_list);
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_stage_answer(p_session_token text, p_stage_id uuid, p_answer text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.teams%rowtype; s public.stages%rowtype; ok boolean; already_done boolean;
BEGIN
  IF p_answer IS NULL OR char_length(trim(p_answer)) = 0 OR char_length(p_answer) > 200 THEN
    RETURN jsonb_build_object('success', false, 'message', 'اكتب إجابة صالحة.');
  END IF;
  SELECT * INTO t FROM public.teams
  WHERE session_token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex') AND is_active = true FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'message', 'انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); END IF;
  SELECT * INTO s FROM public.stages WHERE id = p_stage_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'message', 'المرحلة غير موجودة.'); END IF;
  IF s.status <> 'current' THEN
    RETURN jsonb_build_object('success', false, 'message', 'هذه المرحلة مقفلة حاليًا من المشرف.');
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.answer_submissions WHERE team_id = t.id AND stage_id = s.id AND status = 'accepted') INTO already_done;
  IF already_done THEN
    RETURN jsonb_build_object('success', true, 'correct', true, 'already_completed', true, 'message', 'أنجزتم هذه المرحلة سابقًا، ونقاطها محفوظة.');
  END IF;
  ok := encode(extensions.digest(lower(trim(p_answer)), 'sha256'), 'hex') = s.answer_hash;
  INSERT INTO public.answer_submissions(team_id, stage_id, answer_text, is_correct, status)
  VALUES(t.id, s.id, trim(p_answer), ok, CASE WHEN ok THEN 'accepted' ELSE 'rejected' END);
  IF ok THEN
    UPDATE public.teams SET points = points + s.points_reward, progress = progress + 1 WHERE id = t.id;
    INSERT INTO public.audit_logs(action, entity_type, entity_id, details)
    VALUES('correct_answer', 'stage', s.id::text, jsonb_build_object('team_id', t.id, 'points', s.points_reward));
    RETURN jsonb_build_object('success', true, 'correct', true, 'already_completed', false,
      'points_awarded', s.points_reward, 'message', 'إجابة صحيحة! أُضيفت نقاط المرحلة إلى رصيد فريقكم.');
  END IF;
  RETURN jsonb_build_object('success', true, 'correct', false, 'message', 'مو هي الإجابة الصحيحة، راجعوا الأدلة وحاولوا مرة ثانية.');
END;
$$;