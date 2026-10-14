import { useEffect, useMemo, useState } from 'react';
import { ArrowLeft, ArrowUpLeft, BadgeCheck, BookOpen, Check, ChevronLeft, CircleHelp, Clock3, Compass, Crown, Eye, EyeOff, Flag, KeyRound, Lightbulb, LockKeyhole, MapPin, Menu, Radio, RefreshCw, ShieldCheck, Sparkles, Swords, Trophy, Users, X, Zap } from 'lucide-react';
import { isSupabaseConfigured, supabase } from './lib/supabase.js';

const demoStages = [
  { id:'demo-1', title:'البداية', number:'01', description:'أول خيط في رحلة الكنز', status:'current', prompt:'تأمل المكان حولك. ابحث عن أول دليل مخبأ في بداية الرحلة، واجمع ملاحظات فريقك قبل الإجابة.', hint:'ابحث عن المكان الذي تبدأ منه كل حكاية.' },
  { id:'demo-2', title:'الأثر المفقود', number:'02', description:'اجمعوا الأدلة واربطوا بينها', status:'locked', hint:'الأثر لا يتكلم، لكن مكانه يدل عليه.' },
  { id:'demo-3', title:'شفرة الحارس', number:'03', description:'فكوا الرمز قبل بقية الفرق', status:'locked', hint:'أحيانًا تكون الإجابة أمام عينيك.' },
  { id:'demo-4', title:'الكنز الأخير', number:'04', description:'اقتربتم من خط النهاية', status:'locked', hint:'كل خطوة صحيحة تقربكم من الكنز.' }
];
const familyColorLabels = { white:'الأبيض', blue:'الأزرق', yellow:'الأصفر' };
const familyColorClasses = { white:'white', blue:'blue', yellow:'yellow' };
const deviceIdStorageKey = 'shifrat-device-id';
function getDeviceId(){
  let id = localStorage.getItem(deviceIdStorageKey);
  if(!id){
    id = typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : Array.from(crypto.getRandomValues(new Uint8Array(24)),b=>b.toString(16).padStart(2,'0')).join('');
    localStorage.setItem(deviceIdStorageKey,id);
  }
  return id;
}
const demoTeams = [
  {id:'t1',name:'الصقور',points:240,progress:3,color:'gold'},
  {id:'t2',name:'الذئاب',points:180,progress:2,color:'blue'},
  {id:'t3',name:'النمور',points:120,progress:1,color:'purple'}
];

function Brand(){return <div className="brand"><div className="brand-mark"><KeyRound size={22}/></div><div><strong>شفرة ذو النورين</strong><span>رحلة تبدأ بلغز</span></div></div>}

export default function App(){
  const [view,setView]=useState('home'),[teamName,setTeamName]=useState(''),[sessionCode,setSessionCode]=useState(''),[mobileNavOpen,setMobileNavOpen]=useState(false),[welcomeOpen,setWelcomeOpen]=useState(false);
  const [team,setTeam]=useState(null),[stages,setStages]=useState([]),[teams,setTeams]=useState([]),[gameOpen,setGameOpen]=useState(null);
  const [activeStage,setActiveStage]=useState(null),[answer,setAnswer]=useState(''),[feedback,setFeedback]=useState('');
  const [hintVisible,setHintVisible]=useState(false),[busy,setBusy]=useState(false),[notice,setNotice]=useState('');
  const [adminEmail,setAdminEmail]=useState(''),[adminPassword,setAdminPassword]=useState(''),[adminSession,setAdminSession]=useState(false);
  const [newTitle,setNewTitle]=useState(''),[newDescription,setNewDescription]=useState('');
  const blankQuestion=()=>({prompt:'',answer:'',hint:'',finalAnswer:'',points:'100'});
  const [newQuestions,setNewQuestions]=useState([blankQuestion(),blankQuestion(),blankQuestion()]);
  const [answerPhase,setAnswerPhase]=useState('riddle');
  const [adminStages,setAdminStages]=useState([]),[adminTeams,setAdminTeams]=useState([]),[familyCodes,setFamilyCodes]=useState([]),[gameSettings,setGameSettings]=useState({is_open:false}),[editStage,setEditStage]=useState(null),[savingField,setSavingField]=useState('');
  const [familyName,setFamilyName]=useState(''),[familyColor,setFamilyColor]=useState('white'),[newFamilyCode,setNewFamilyCode]=useState('');
  const [showPassword,setShowPassword]=useState(false);
  const [newPassword,setNewPassword]=useState(''),[confirmPassword,setConfirmPassword]=useState('');
  const [registerPassword,setRegisterPassword]=useState(''),[registerConfirmPassword,setRegisterConfirmPassword]=useState('');
  useEffect(()=>{if(!localStorage.getItem('dhulnoorain-welcome-seen'))setWelcomeOpen(true);},[]);
  function closeWelcome(){localStorage.setItem('dhulnoorain-welcome-seen','1');setWelcomeOpen(false)}
  function exitTeam(){if(!window.confirm('هل أنت متأكد أنك تبي تطلع من المسابقة؟ تقدر ترجع تدخل من نفس الجوال برمز الأسرة نفسه.'))return;localStorage.removeItem('shifrat-team-session');setTeam(null);setStages([]);setActiveStage(null);setAnswer('');setFeedback('');setAnswerPhase('riddle');setView('home');setNotice('تم تسجيل خروج الفريق. تقدرون تدخلون مرة ثانية برمز الأسرة.');}
  const completed=useMemo(()=>stages.filter(s=>s.status==='completed').length,[stages]);
  const currentStage=(activeStage&&stages.find(s=>s.id===activeStage.id))||stages.find(s=>s.status==='current')||null;
  useEffect(()=>{if(currentStage?.status==='current'&&currentStage.hint_unlocked)setAnswerPhase('final');else if(!currentStage?.hint_unlocked)setAnswerPhase('riddle');},[currentStage?.id,currentStage?.status,currentStage?.hint_unlocked]);

  async function refreshTeamState(token,{silent=false}={}){
    if(!isSupabaseConfigured||!token)return false;
    const {data,error}=await supabase.rpc('get_team_game_state',{p_session_token:token,p_device_id:getDeviceId()});
    if(error||!data?.success){
      if(!silent||data?.code==='device_mismatch')setNotice(data?.message||'تعذر تحميل تقدم الفريق. حاول تسجيل الدخول من جديد.');
      localStorage.removeItem('shifrat-team-session');
      setTeam(null);
      if(data?.code==='device_mismatch')setView('home');
      return false;
    }
    setTeam({...data.team,token});
    if(typeof data.game_open==='boolean')setGameOpen(data.game_open);
    setStages(Array.isArray(data.stages)?data.stages:[]);
    return true;
  }

  useEffect(()=>{
    if(!isSupabaseConfigured)return;
    const initialHash=new URLSearchParams(window.location.hash.slice(1));
    if(initialHash.get('error_code')==='otp_expired'||initialHash.get('error')==='access_denied'){
      setView('admin-login');
      setNotice('رابط الاستعادة منتهي الصلاحية أو غير صالح. اطلب رابطًا جديدًا بعد تجهيز الإعدادات.');
      window.history.replaceState(null,'',window.location.pathname+window.location.search);
    }
    supabase.auth.getSession().then(({data})=>{
      if(data.session?.user?.app_metadata?.role==='game_admin'){setAdminSession(true);setView('admin');}
    });
    const {data:authListener}=supabase.auth.onAuthStateChange((event,session)=>{
      if(event==='PASSWORD_RECOVERY'){setView('reset-password');setNotice('');}
      if(session?.user?.app_metadata?.role==='game_admin')setAdminSession(true);
      else if(!session)setAdminSession(false);
    });
    let live=true;
    async function load(){
      const [a,b,status]=await Promise.all([
        supabase.from('public_stages').select('id,title,number,description,status,sort_order,points_reward').order('sort_order'),
        supabase.from('public_leaderboard').select('id,name,points,progress').order('points',{ascending:false}).limit(10),
        supabase.rpc('get_game_status')
      ]);
      if(!live)return;
      setGameOpen(status.data?.success?Boolean(status.data.is_open):false);
      if(b.data)setTeams(b.data.map((t,i)=>({...t,color:t.color||['white','blue','yellow'][i%3]})));
      const saved=localStorage.getItem('shifrat-team-session');
      if(saved){
        try{
          const session=JSON.parse(saved);
          if(session?.token&&await refreshTeamState(session.token,{silent:true})){setView('game');return;}
        }catch{}
      }
      if(a.data)setStages(a.data.map(s=>({...s,prompt:null,hint:null,scrambled_sentence:null})));
    }
    load();
    const statusPoll=setInterval(async()=>{
      const {data}=await supabase.rpc('get_game_status');
      if(data?.success)setGameOpen(Boolean(data.is_open));
      const savedSession=localStorage.getItem('shifrat-team-session');
      if(savedSession){try{const parsed=JSON.parse(savedSession);if(parsed?.token)await refreshTeamState(parsed.token,{silent:true});}catch{}}
    },5000);
    const ch=supabase.channel('game-public-updates')
      .on('postgres_changes',{event:'*',schema:'public',table:'stages'},load)
      .on('postgres_changes',{event:'*',schema:'public',table:'teams'},load)
      .on('postgres_changes',{event:'*',schema:'public',table:'game_settings'},load).subscribe();
    return()=>{live=false;clearInterval(statusPoll);supabase.removeChannel(ch);authListener.subscription.unsubscribe()};
  },[]);

  async function refreshAdminData(){
    if(!isSupabaseConfigured||!adminSession)return;
    const [stageRes,teamRes,codeRes,settingsRes,questionRes]=await Promise.all([
      supabase.from('stages').select('id,title,number,description,prompt,hint,scrambled_sentence,answer_hash,answer_text,final_answer_text,status,sort_order,points_reward').order('sort_order'),
      supabase.from('teams').select('id,name,points,progress,color,is_active,created_at').order('created_at',{ascending:false}),
      supabase.from('family_codes').select('id,family_name,color,is_active,used_by_team,created_at,used_at').order('created_at',{ascending:false}),
      supabase.from('game_settings').select('is_open,game_title').eq('id',true).maybeSingle(),
      supabase.from('stage_questions').select('id,stage_id,variant_no,prompt,answer_hash,answer_text,hint,scrambled_sentence,final_answer_hash,final_answer_text,points_reward').order('variant_no')
    ]);
    if(stageRes.data)setAdminStages(stageRes.data.map(s=>({...s,questions:(questionRes.data||[]).filter(q=>q.stage_id===s.id)})));
    if(teamRes.data)setAdminTeams(teamRes.data);
    if(codeRes.data)setFamilyCodes(codeRes.data);
    if(settingsRes.data)setGameSettings(settingsRes.data);
  }

  useEffect(()=>{if(view==='admin'&&adminSession)refreshAdminData();},[view,adminSession]);

  async function joinGame(e){
    e.preventDefault();setNotice('');
    if(!teamName.trim()||!sessionCode.trim()){setNotice('أدخل اسم الفريق ورمز الدخول.');return}
    if(!isSupabaseConfigured){setNotice('الموقع غير متصل بقاعدة البيانات حاليًا. حاول لاحقًا.');return}
    setBusy(true);
    const {data,error}=await supabase.rpc('join_game',{p_team_name:teamName.trim(),p_session_code:sessionCode.trim(),p_device_id:getDeviceId()});
    setBusy(false);
    if(error||!data?.success){setNotice(data?.message||'تعذر الدخول. تحقق من رمز الأسرة وحالة المسابقة.');return}
    const saved={id:data.team_id,name:data.team_name,token:data.session_token};
    localStorage.setItem('shifrat-team-session',JSON.stringify(saved));
    setTeam(saved);
    await refreshTeamState(data.session_token,{silent:true});
    setView('game');setActiveStage(null);setFeedback('');setAnswerPhase('riddle');setHintVisible(false);
  }

  async function submitAnswer(e){
    e.preventDefault();if(!answer.trim()||!currentStage)return;
    if(!team?.token||!currentStage||currentStage.status==='locked'||currentStage.status==='completed')return;
    setBusy(true);setFeedback('');
    const {data,error}=await supabase.rpc('submit_stage_answer',{p_session_token:team.token,p_stage_id:currentStage.id,p_answer:answer.trim(),p_device_id:getDeviceId(),p_phase:answerPhase});
    setBusy(false);
    if(error){setFeedback('تعذر إرسال الإجابة الآن. تحقق من اتصال الإنترنت ثم حاول مجددًا.');return}
    setFeedback(data?.message||'تم استلام الإجابة.');
    if(data?.correct&&data?.phase_complete){setActiveStage(null);setAnswer('');setAnswerPhase('riddle');setHintVisible(false);}
    else if(data?.correct&&data?.hint_unlocked){setAnswer('');setAnswerPhase('final');setHintVisible(true);}
    await refreshTeamState(team.token,{silent:true});
  }

  async function adminLogin(e){
    e.preventDefault();setNotice('');
    if(!isSupabaseConfigured){setNotice('أضف إعدادات Supabase أولًا ثم أنشئ حساب المشرف واضبط دوره game_admin.');return}
    setBusy(true);
    const {data,error}=await supabase.auth.signInWithPassword({email:adminEmail.trim(),password:adminPassword});
    if(error){setBusy(false);setNotice('تعذر تسجيل الدخول. تحقق من البريد وكلمة المرور.');return}
    if(data.user?.app_metadata?.role!=='game_admin'){
      await supabase.auth.signOut();setBusy(false);setNotice('هذا الحساب غير مخوّل كمشرف. اضبط app_metadata.role إلى game_admin في Supabase.');return;
    }
    setBusy(false);setAdminSession(true);setView('admin');
  }

  async function registerAdminAccount(e){
    e.preventDefault();setNotice('');
    if(!isSupabaseConfigured){setNotice('خدمة إنشاء الحساب غير متصلة حاليًا.');return}
    if(registerPassword.length<8){setNotice('اجعل كلمة المرور 8 أحرف على الأقل.');return}
    if(registerPassword!==registerConfirmPassword){setNotice('كلمتا المرور غير متطابقتين.');return}
    setBusy(true);
    const redirectTo=window.location.origin+import.meta.env.BASE_URL;
    const {data,error}=await supabase.auth.signUp({
      email:adminEmail.trim(),
      password:registerPassword,
      options:{emailRedirectTo:redirectTo}
    });
    setBusy(false);
    if(error){
      setNotice(error.message?.toLowerCase().includes('rate limit')
        ?'تم طلب رسائل كثيرة. انتظر قليلًا قبل المحاولة مرة أخرى.'
        :'تعذر إنشاء الحساب. تأكد من البريد أو جرّب بريدًا غير مسجل من قبل.');
      return;
    }
    setRegisterPassword('');setRegisterConfirmPassword('');
    setView('admin-login');
    if(data.user?.identities?.length===0){
      setNotice('هذا البريد مسجل بالفعل. لا تحتاج إلى تسجيل جديد؛ استخدم استعادة كلمة المرور بعد انتهاء حد إرسال الرسائل.');
      return;
    }
    setNotice(data.session
      ?'تم إنشاء الحساب، لكنه لا يملك صلاحية المشرف بعد. لن تتمكن من دخول لوحة التحكم حتى تُمنح الصلاحية بأمان.'
      :'تم إرسال طلب إنشاء الحساب إن كان البريد جديدًا. افحص البريد والت spam، ولا تكرر الطلب إذا كان البريد مسجلًا بالفعل.');
  }

  async function createFamilyCode(e){
    e.preventDefault();setNotice('');setNewFamilyCode('');
    if(!isSupabaseConfigured||!adminSession){setNotice('سجّل دخول المشرف أولًا.');return}
    if(familyName.trim().length<2){setNotice('اكتب اسم الأسرة (حرفان على الأقل).');return}
    const bytes=crypto.getRandomValues(new Uint8Array(6));
    const code=Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('').toUpperCase();
    const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(code.toLowerCase()));
    const codeHash=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('');
    const {data:userData}=await supabase.auth.getUser();
    const {error}=await supabase.from('family_codes').insert({family_name:familyName.trim(),color:familyColor,code_hash:codeHash,created_by:userData.user?.id});
    if(error){setNotice('تعذر إنشاء الرمز. تأكد من تحديث قاعدة البيانات ومن صلاحية المشرف.');return}
    setNewFamilyCode(code);setFamilyName('');setNotice(`تم إنشاء رمز الأسرة باللون ${familyColorLabels[familyColor]}. انسخه وأرسله للأسرة؛ لن يُعرض كاملًا مرة أخرى.`);
  }

  async function hashAnswer(value){
    const bytes=new TextEncoder().encode(value.trim().toLowerCase());
    const digest=await crypto.subtle.digest('SHA-256',bytes);
    return Array.from(new Uint8Array(digest)).map(b=>b.toString(16).padStart(2,'0')).join('');
  }

  async function requestHint(){
    if(!team?.token||!currentStage||currentStage.status!=='current'||busy)return;
    if(currentStage.hint_used){setFeedback('استخدمتم تلميحة لهذه المرحلة بالفعل.');return;}
    if((team.hints_remaining??(3-(team.hints_used||0)))<=0){setFeedback('استهلكتم التلميحات الثلاث المتاحة للأسرة.');return;}
    if(!window.confirm('استخدام التلميحة سيخصم نصف نقاط هذه المرحلة، وسيُحتسب من التلميحات الثلاث المتاحة للأسرة. هل تريدون المتابعة؟'))return;
    setBusy(true);setFeedback('');
    const {data,error}=await supabase.rpc('request_team_hint',{p_session_token:team.token,p_stage_id:currentStage.id,p_device_id:getDeviceId()});
    setBusy(false);
    if(error||!data?.success){setFeedback(data?.message||'تعذر تسجيل التلميحة. حاولوا مرة أخرى.');return;}
    setTeam(v=>({...v,hints_used:data.hints_used,hints_remaining:data.hints_remaining}));
    setStages(v=>v.map(stage=>stage.id===currentStage.id?({...stage,hint_used:true}):stage));
    setFeedback(data.message||'روحوا للمسؤول عن البرنامج يعطيكم التلميحة.');
    await refreshTeamState(team.token,{silent:true});
  }

  function updateNewQuestion(index,key,value){
    setNewQuestions(current=>current.map((q,i)=>i===index?({...q,[key]:value}):q));
  }

  async function saveQuestionField(index,field){
    if(!editStage)return;
    const q=editStage.questions?.[index];
    if(!q?.id||!q?.stage_id&&!editStage.id){setNotice('تعذر تحديد السؤال. أغلق نافذة التعديل وافتحها من جديد.');return;}
    const key=`${q.id}:${field}`;
    setSavingField(key);setNotice('');
    try{
      let patch={};
      let nextValue;
      if(field==='prompt'){nextValue=(q.prompt||'').trim();if(!nextValue){setNotice('اكتب نص السؤال قبل الحفظ.');return;}patch={prompt:nextValue};}
      else if(field==='hint'){nextValue=q.hint||'';patch={hint:nextValue,scrambled_sentence:nextValue};}
      else if(field==='answer'){
        nextValue=(q.newAnswer||'').trim();
        if(!nextValue){setNotice('اكتب الإجابة الصحيحة قبل الحفظ.');return;}
        patch={answer_text:nextValue,answer_hash:await hashAnswer(nextValue)};
      }else if(field==='finalAnswer'){
        nextValue=(q.newFinalAnswer||'').trim();
        if(!nextValue){setNotice('اكتب الحل النهائي قبل الحفظ.');return;}
        patch={final_answer_text:nextValue,final_answer_hash:await hashAnswer(nextValue)};
      }else if(field==='points'){nextValue=Math.max(0,Math.min(10000,Number(q.points_reward)||0));patch={points_reward:nextValue};}
      const {data:updatedRow,error:updateError}=await supabase.from('stage_questions').update(patch).eq('id',q.id).eq('stage_id',editStage.id).select('id').maybeSingle();
      if(updateError){setNotice(`فشل الحفظ: ${updateError.message||'تحقق من صلاحية المشرف واتصال قاعدة البيانات.'}`);return;}
      if(!updatedRow){setNotice('لم يتم تحديث أي سجل في قاعدة البيانات. سجّل خروجك من لوحة المشرف ثم ادخل مجددًا، وإذا استمرت المشكلة نراجع صلاحيات قاعدة البيانات.');return;}
      const {data:verify,error:verifyError}=await supabase.from('stage_questions').select('id,prompt,hint,scrambled_sentence,answer_text,answer_hash,final_answer_text,final_answer_hash,points_reward').eq('stage_id',editStage.id).eq('variant_no',q.variant_no).maybeSingle();
      if(verifyError||!verify){setNotice(verifyError?`تعذر التأكد من الحفظ: ${verifyError.message}`:'لم يعثر النظام على نسخة السؤال بعد الحفظ.');return;}
      const verifyField={prompt:'prompt',hint:'hint',answer:'answer_text',finalAnswer:'final_answer_text',points:'points_reward'}[field];
      const storedValue=verify?.[verifyField];
      const matches=field==='points'?Number(storedValue)===Number(nextValue):(storedValue??'')===(nextValue??'')&&(field!=='hint'||(verify.scrambled_sentence??'')===(nextValue??''));
      if(!matches){setNotice('لم يتغير الحقل في قاعدة البيانات. غالبًا صلاحية التعديل مرفوضة أو لم يصل التحديث؛ جرّب تسجيل الخروج من لوحة المشرف ثم الدخول مجددًا.');return;}
      let saveMessage='تم حفظ الحقل المحدد والتأكد من تطابقه مع قاعدة البيانات.';
      if(q.variant_no===1&&['prompt','hint','answer','finalAnswer','points'].includes(field)){
        const legacyPatch=field==='prompt'?{prompt:nextValue}:field==='hint'?{hint:nextValue,scrambled_sentence:nextValue}:field==='answer'?{answer_text:nextValue,answer_hash:patch.answer_hash}:field==='finalAnswer'?{final_answer_text:nextValue}:{points_reward:nextValue};
        const {error:legacyError}=await supabase.from('stages').update(legacyPatch).eq('id',editStage.id);
        if(legacyError)saveMessage='تم حفظ الحقل في نسخة السؤال، لكن تعذّر تحديث بيانات المرحلة العامة.';
      }
      const {data:readiness,error:readinessError}=await supabase.from('stage_questions').select('variant_no,prompt,answer_text,final_answer_text').eq('stage_id',editStage.id).order('variant_no');
      if(!readinessError&&readiness?.length===3){
        const complete=readiness.every(row=>row.prompt&&row.prompt.trim()&&row.prompt!=='لم يُضف السؤال بعد'&&row.answer_text&&row.answer_text.trim()&&row.final_answer_text&&row.final_answer_text.trim());
        if(complete){
          const {data:currentRows}=await supabase.from('stages').select('id').eq('status','current').neq('id',editStage.id).limit(1);
          if(!currentRows?.length)await supabase.from('stages').update({status:'current',description:(editStage.description||'').replace('مسودة مرحلة — أكمل الحقول قبل بدء اللعب','')||'مرحلة مكتملة'}).eq('id',editStage.id);
        }
      }
      setEditStage(v=>({...v,questions:v.questions.map((item,j)=>j!==index?item:({...item,
        prompt:verify.prompt,
        hint:verify.hint,
        scrambled_sentence:verify.scrambled_sentence,
        answer_text:verify.answer_text,
        answer_hash:verify.answer_hash,
        final_answer_text:verify.final_answer_text,
        final_answer_hash:verify.final_answer_hash,
        points_reward:verify.points_reward,
        ...(field==='answer'?{newAnswer:verify.answer_text||''}:{}),
        ...(field==='finalAnswer'?{newFinalAnswer:verify.final_answer_text||''}:{})
      }))}));
      setNotice(saveMessage);
      await refreshAdminData();
    }catch(err){
      setNotice(`حدث خطأ أثناء الحفظ: ${err?.message||'حاول مرة أخرى.'}`);
    }finally{
      setSavingField('');
    }
  }

  async function createStage(e){
    e.preventDefault();
    if(!newTitle.trim()){setNotice('اكتب عنوان المرحلة أولًا.');return;}
    if(!isSupabaseConfigured||!adminSession){setNotice('يلزم تسجيل دخول المشرف وربط Supabase لحفظ المرحلة.');return}
    setBusy(true);setNotice('');
    try{
      const sortOrder=Math.max(0,...adminStages.map(s=>Number(s.sort_order)||0))+1;
      const placeholder='__DRAFT_NOT_READY__';
      const placeholderHash=await hashAnswer(placeholder);
      const {data:stage,error}=await supabase.from('stages').insert({
        title:newTitle.trim(),prompt:'لم يُضف السؤال بعد',answer_hash:placeholderHash,answer_text:null,final_answer_text:null,
        hint:'',scrambled_sentence:'',status:'locked',sort_order:sortOrder,points_reward:100,
        description:newDescription.trim()||'مسودة مرحلة — أكمل الحقول قبل بدء اللعب'
      }).select('id').single();
      if(error||!stage){setNotice(`لم يتم إنشاء المسودة: ${error?.message||'تحقق من صلاحيات المشرف واتصال قاعدة البيانات.'}`);return;}
      const variants=[1,2,3].map(variant_no=>({
        stage_id:stage.id,variant_no,prompt:'لم يُضف السؤال بعد',answer_hash:placeholderHash,answer_text:null,
        hint:'',scrambled_sentence:'',final_answer_hash:placeholderHash,final_answer_text:null,points_reward:100
      }));
      const {error:questionError}=await supabase.from('stage_questions').insert(variants);
      if(questionError){
        await supabase.from('stages').delete().eq('id',stage.id);
        setNotice(`تعذر إنشاء حقول المسودة: ${questionError.message||'حاول مرة أخرى.'}`);return;
      }
      setNewTitle('');setNewDescription('');setNewQuestions([blankQuestion(),blankQuestion(),blankQuestion()]);
      setNotice('تم إنشاء مسودة المرحلة. افتح «تعديل» واحفظ كل حقل لحاله؛ المرحلة مقفلة عن الأسر حتى تكتمل الأسئلة الثلاثة.');
      await refreshAdminData();
      const {data:created}=await supabase.from('stages').select('id,title,number,description,prompt,hint,scrambled_sentence,answer_hash,answer_text,final_answer_text,status,sort_order,points_reward').eq('id',stage.id).single();
      const {data:questions}=await supabase.from('stage_questions').select('id,stage_id,variant_no,prompt,answer_hash,answer_text,hint,scrambled_sentence,final_answer_hash,final_answer_text,points_reward').eq('stage_id',stage.id).order('variant_no');
      if(created)setEditStage({...created,newAnswer:created.answer_text||'',newFinalAnswer:created.final_answer_text||'',questions:(questions||[]).map(q=>({...q,newAnswer:q.answer_text||'',newFinalAnswer:q.final_answer_text||''}))});
    }catch(err){setNotice(`حدث خطأ أثناء إنشاء المسودة: ${err?.message||'حاول مرة أخرى.'}`);}
    finally{setBusy(false);}
  }

  async function requestPasswordRecovery(e){
    e.preventDefault();setNotice('');
    if(!isSupabaseConfigured){setNotice('خدمة تسجيل الدخول غير متصلة حاليًا.');return}
    setBusy(true);
    const redirectTo=window.location.origin+import.meta.env.BASE_URL;
    const {error}=await supabase.auth.resetPasswordForEmail(adminEmail.trim(),{redirectTo});
    setBusy(false);
    if(error){
      setNotice(error.message?.toLowerCase().includes('rate limit')
        ?'تم طلب رسائل الاستعادة كثيرًا. انتظر قليلًا قبل المحاولة مرة أخرى.'
        :'تعذر إرسال رابط الاستعادة. تحقق من البريد وإعدادات الروابط في Supabase.');
      return;
    }
    setNotice('إذا كان البريد مسجلًا، فسيصلك رابط استعادة. افتحه من نفس الجهاز، ثم اختر كلمة مرور جديدة.');
  }

  async function saveNewPassword(e){
    e.preventDefault();setNotice('');
    if(newPassword.length<8){setNotice('اجعل كلمة المرور 8 أحرف على الأقل.');return}
    if(newPassword!==confirmPassword){setNotice('كلمتا المرور غير متطابقتين.');return}
    setBusy(true);
    const {error}=await supabase.auth.updateUser({password:newPassword});
    setBusy(false);
    if(error){setNotice('تعذر تغيير كلمة المرور. قد يكون رابط الاستعادة انتهت صلاحيته؛ اطلب رابطًا جديدًا.');return}
    await supabase.auth.signOut();
    setNewPassword('');setConfirmPassword('');setAdminPassword('');
    setView('admin-login');setNotice('تم تغيير كلمة المرور بنجاح. سجّل الدخول بكلمة المرور الجديدة.');
  }

  async function adminLogout(){if(supabase)await supabase.auth.signOut();setAdminSession(false);setView('home')}

  return <div className="app-shell">
    <header className="topbar"><Brand/><nav className="desktop-nav">
      {!(view==='game'&&team)&&<><button className={view==='home'?'nav-link active':'nav-link'} onClick={()=>setView('home')}>الرئيسية</button>
      <button className={view==='leaderboard'?'nav-link active':'nav-link'} onClick={()=>setView('leaderboard')}>لوحة الترتيب</button>
      <button className="nav-link" onClick={()=>{setView('admin-login');setNotice('')}}>المشرف <LockKeyhole size={14}/></button></>}
    </nav>{!(view==='game'&&team)&&<button className="mobile-menu" aria-label="القائمة" aria-expanded={mobileNavOpen} onClick={()=>setMobileNavOpen(v=>!v)}><Menu/></button>}
    <div className="live-pill"><span className="live-dot"/>{!isSupabaseConfigured?'وضع المعاينة':gameOpen===null?'جارٍ التحقق':gameOpen?'المسابقة مفتوحة':'المسابقة مغلقة'}</div></header>
    {mobileNavOpen&&!(view==='game'&&team)&&<nav className="mobile-nav-panel" aria-label="القائمة الرئيسية"><button className={view==='home'?'nav-link active':'nav-link'} onClick={()=>{setView('home');setMobileNavOpen(false)}}>الرئيسية</button><button className={view==='leaderboard'?'nav-link active':'nav-link'} onClick={()=>{setView('leaderboard');setMobileNavOpen(false)}}>لوحة الترتيب</button><button className="nav-link" onClick={()=>{setView('admin-login');setMobileNavOpen(false);setNotice('')}}>المشرف <LockKeyhole size={14}/></button></nav>}
    {notice&&<div className="notice" role="status"><span>{notice}</span><button onClick={()=>setNotice('')} aria-label="إغلاق"><X size={16}/></button></div>}

    {view==='home'&&<main>
      <section className="hero"><div className="hero-copy"><div className="eyebrow"><Sparkles size={15}/> تحدٍّ للعقول الشجاعة</div>
        <h1>كل لغز يقرّبك<br/><span>من الكنز.</span></h1>
        <p className="hero-description">كوّن فريقك، فك الشفرات، واتبع الأدلة. رحلة مليئة بالتحديات تنتظر من يملك عينًا تلاحظ وعقلًا يربط التفاصيل.</p>
        <div className="hero-actions"><button className="btn btn-gold" onClick={()=>document.getElementById('join-card')?.scrollIntoView({behavior:'smooth',block:'center'})}><Swords size={18}/> ابدأ المغامرة <ArrowLeft size={17}/></button><button className="btn btn-ghost" onClick={()=>setView('leaderboard')}>شاهد ترتيب الفرق <ChevronLeft size={17}/></button></div>
        <div className="hero-stats"><div><strong>{teams.length.toLocaleString('ar')}</strong><span>فرق مشاركة</span></div><i/><div><strong>{stages.length.toLocaleString('ar')}</strong><span>مراحل التحدي</span></div><i/><div><strong>{completed.toLocaleString('ar')}</strong><span>مراحل مكتملة</span></div></div>
      </div><div className="hero-art" aria-label="رسم توضيحي لصندوق كنز"><div className="orbit orbit-one"/><div className="orbit orbit-two"/><div className="star star-a">✦</div><div className="star star-b">✧</div><div className="star star-c">✦</div><div className="treasure-glow"/><div className="treasure-chest"><div className="chest-lid"><div className="chest-band"/></div><div className="chest-body"><div className="chest-band"/><div className="chest-lock"><KeyRound size={25}/></div></div><div className="chest-foot left"/><div className="chest-foot right"/></div><div className="floating-tag tag-top"><Compass size={15}/> اتبع الدليل</div><div className="floating-tag tag-bottom"><Zap size={15}/> فك الشفرة</div><div className="art-caption">الكنز لا يصل إليه إلا من يبحث</div></div></section>

      <section className="join-section" id="join-card"><div className="section-heading"><div className="section-icon"><KeyRound size={20}/></div><div><h2>ادخل إلى ساحة التحدي</h2><p>أدخل اسم الفريق ورمز الأسرة. يمكن لجميع أفراد الأسرة الدخول بالرمز نفسه.</p></div></div>
        <form className="join-form" onSubmit={joinGame}><label>اسم الفريق<div className="input-wrap"><Users size={18}/><input value={teamName} onChange={e=>setTeamName(e.target.value)} placeholder="مثال: صقور الصحراء" maxLength={50} required/></div></label>
        <label>رمز الدخول<div className="input-wrap"><KeyRound size={18}/><input value={sessionCode} onChange={e=>setSessionCode(e.target.value)} placeholder="أدخل الرمز الذي استلمته" maxLength={80} required/></div></label>
        <button className="btn btn-gold join-submit" disabled={busy}>{busy?<RefreshCw className="spin" size={18}/>:<ArrowUpLeft size={18}/>} {busy?'جارٍ التحقق...':'دخول الفريق'}</button></form>
        <div className="secure-note"><ShieldCheck size={15}/> شاركوا رمز الأسرة نفسه مع جميع أفراد الأسرة؛ كل شخص يدخل بجلسة مستقلة ويشترك معكم في النقاط والتلميحات.</div></section>

      <section className="stages-section"><div className="section-title-row"><div><div className="eyebrow">خارطة الرحلة</div><h2>مراحل البحث عن الكنز</h2></div><span className="muted-label">{stages.length} مراحل</span></div>
        <div className="stage-grid">{stages.length?stages.map((s,i)=><button className={'stage-card '+s.status} key={s.id} onClick={()=>{if(s.status!=='locked'){setActiveStage(s);if(team)setView('game');else setNotice('ادخل بيانات فريقك أولًا لبدء المرحلة.')}}}>
          <div className="stage-card-top"><span className="stage-number">{s.number||String(i+1).padStart(2,'0')}</span>{s.status==='completed'?<BadgeCheck size={19}/>:s.status==='locked'?<LockKeyhole size={18}/>:<Radio size={18}/>}</div><h3>{s.title}</h3><p>{s.description||'اكتشف الدليل التالي في رحلتك'}</p><div className="stage-card-footer"><span>{s.status==='completed'?'مكتملة':s.status==='locked'?'مقفلة':'متاحة الآن'}</span><ChevronLeft size={16}/></div>
        </button>):<div className="empty-state">تُعرض مراحل البحث هنا بعد تجهيزها من منظّم المسابقة.</div>}</div></section>
      <section className="bottom-banner"><div className="banner-emblem"><Trophy size={27}/></div><div><h2>هل فريقك مستعد للتحدي؟</h2><p>كل ثانية تصنع فرقًا. وكل دليل يقربك من الفوز.</p></div><button className="btn btn-outline" onClick={()=>document.getElementById('join-card')?.scrollIntoView({behavior:'smooth',block:'center'})}>انطلق الآن <ArrowLeft size={16}/></button></section>
    </main>}

    {view==='game'&&(gameOpen===false?<main className="paused-screen"><div className="paused-content"><div className="paused-mark"><LockKeyhole size={34}/></div><p className="paused-eyebrow">شفرة ذو النورين</p><h1>المشرف أوقف المسابقة</h1><p>سيتم البدء بعد موافقة المشرف.</p><span className="paused-indicator"><i/> المسابقة متوقفة مؤقتًا</span><button className="btn btn-exit" onClick={exitTeam}><ArrowLeft size={17}/> الخروج من المسابقة</button></div></main>:<main className="game-view">
      <div className="game-header"><div><div className="eyebrow"><Radio size={14}/> ساحة التحدي</div><h1>حيّاكم يا <span>{team?.name||teamName}</span></h1><p>ركزوا مع بعض، كل تفصيلة ممكن تكون المفتاح.</p></div><div className={`team-badge team-color-badge color-${team?.color||'white'}`}><span className="team-color-dot"/><span>لونكم: {familyColorLabels[team?.color]||'الأبيض'}</span></div></div>
      <div className="game-layout"><section className="panel puzzle-panel"><div className="panel-kicker"><span className="puzzle-icon"><CircleHelp size={22}/></span><span>{currentStage?.status==='completed'?'مرحلة مكتملة':'المرحلة المختارة'} <b>{currentStage?.number||'—'}</b></span></div>
        <h2>{currentStage?.title||(stages.length?'أكملتم المراحل المتاحة!':'الرحلة تستعد للانطلاق')}</h2><p className="puzzle-prompt">{currentStage?.prompt||(stages.length?'ترقّبوا إضافة المراحل التالية من منظّم المسابقة.':'لم تُضف مراحل المسابقة بعد. ارجعوا قريبًا لبدء المغامرة.')}</p>
        {currentStage?.hint_unlocked&&<div className="hint-box"><MapPin size={17}/><span>{currentStage.hint||'اتبعوا التلميح للعثور على الورقة المخبأة.'}</span></div>}
        <div className="hint-request-row"><div><strong>التلميحات المتاحة للأسرة</strong><p>{Math.max(0,team?.hints_remaining??(3-(team?.hints_used||0)))} من 3 متبقية · التلميحة تقلل نقاط هذه المرحلة للنصف</p></div><button type="button" className="btn btn-ghost" onClick={requestHint} disabled={busy||!currentStage||currentStage.status!=='current'||currentStage.hint_used||(team?.hints_remaining??(3-(team?.hints_used||0)))<=0}>{currentStage?.hint_used?'استخدمتم تلميحة هذه المرحلة':'طلب تلميحة من المشرف'}</button></div><form className="answer-form" onSubmit={submitAnswer}><label htmlFor="answer">{answerPhase==='riddle'?'إجابة السؤال':'الحل النهائي من الورقة'}</label><div className="input-wrap answer-input"><input id="answer" value={answer} onChange={e=>setAnswer(e.target.value)} placeholder={answerPhase==='final'?'رتّب الحروف أو الكلمات واكتب الحل هنا':'اكتب إجابة السؤال هنا...'} maxLength={200} disabled={!currentStage||currentStage.status!=='current'||busy||(answerPhase==='final'&&!currentStage.hint_unlocked)} required/><button className="answer-send" disabled={busy||!currentStage||currentStage.status!=='current'||(answerPhase==='final'&&!currentStage.hint_unlocked)}>{busy?<RefreshCw className="spin" size={18}/>:<ArrowLeft size={18}/>}</button></div><p className="answer-help"><LockKeyhole size={13}/> {currentStage?.status==='completed'?'أنجزتم هذه المرحلة بالفعل.':answerPhase==='final'?'اكتبوا الحل النهائي كما رتّبتموه من الورقة.':'الإجابة الصحيحة تفتح التلميح، وبعدها يظهر مربع الحل النهائي.'}</p></form>
        {feedback&&<div className="feedback" role="status">{feedback}</div>}</section>
        <aside className="panel progress-panel"><h3><Flag size={18}/> تقدم الفريق</h3><div className="progress-number"><strong>{completed}</strong><span>من {stages.length} مراحل</span></div><div className="progress-track"><span style={{width:(stages.length?completed/stages.length*100:0)+'%'}}/></div>
          <div className="mini-stage-list">{stages.map((s,i)=><button key={s.id} className={'mini-stage '+s.status} onClick={()=>{if(s.status!=='locked')setActiveStage(s)}}><span className="mini-stage-dot">{s.status==='completed'?<Check size={13}/>:i+1}</span><span>{s.title}</span>{s.status==='locked'&&<LockKeyhole size={14}/>}</button>)}</div>
          <div className="progress-tip"><Sparkles size={16}/><p>تعاونوا ودوّنوا كل دليل؛ التفاصيل الصغيرة قد تصنع الفارق.</p></div></aside></div><div className="game-exit-row"><button className="btn btn-exit" onClick={exitTeam}><ArrowLeft size={17}/> الخروج من المسابقة</button></div></main>)}

    {view==='leaderboard'&&<main className="leaderboard-view"><button className="back-link" onClick={()=>setView('home')}><ArrowLeft size={16}/> العودة للرئيسية</button><div className="leaderboard-hero"><div className="eyebrow"><Trophy size={15}/> المنافسة تحتدم</div><h1>لوحة <span>الأبطال</span></h1><p>الفريق صاحب أعلى رصيد من النقاط هو الفائز بالكنز.</p></div><section className="panel leaderboard-panel"><div className="leaderboard-head"><h2><Crown size={20}/> ترتيب الفرق</h2><span className="live-pill"><span className="live-dot"/> مباشر</span></div>
      {[...teams].sort((a,b)=>b.points-a.points).map((t,i)=><div className={'leader-row '+(i===0?'first':'')} key={t.id}><span className={'rank rank-'+(i+1)}>{i===0?<Crown size={17}/>:String(i+1).padStart(2,'0')}</span><div className={'team-avatar '+(t.color||'blue')}>{(t.name||'?').slice(0,1)}</div><div className="leader-team"><strong>{t.name}</strong><span>{t.progress||0} مراحل مكتملة</span></div><div className="leader-points"><strong>{Number(t.points||0).toLocaleString('ar')}</strong><span>نقطة</span></div><div className="leader-progress"><span style={{width:Math.min(100,(t.progress||0)/Math.max(1,stages.length)*100)+'%'}}/></div></div>)}
      {!teams.length&&<p className="empty-state">ستظهر الفرق هنا عند بدء المسابقة.</p>}</section></main>}

    {view==='admin-login'&&<main className="admin-login-view"><div className="admin-login-card"><div className="admin-lock"><LockKeyhole size={27}/></div><div className="eyebrow">منطقة محمية</div><h1>دخول <span>المشرف</span></h1><p>سجّل الدخول لإدارة مراحل المسابقة والفرق.</p><form onSubmit={adminLogin}>
      <label>البريد الإلكتروني<div className="input-wrap"><Users size={17}/><input type="email" value={adminEmail} onChange={e=>setAdminEmail(e.target.value)} placeholder="admin@example.com" required/></div></label>
      <label>كلمة المرور<div className="input-wrap"><KeyRound size={17}/><input type={showPassword?'text':'password'} value={adminPassword} onChange={e=>setAdminPassword(e.target.value)} placeholder="كلمة المرور" required/><button type="button" className="field-action" onClick={()=>setShowPassword(v=>!v)}>{showPassword?<EyeOff size={17}/>:<Eye size={17}/>}</button></div></label>
      <button className="btn btn-gold join-submit" disabled={busy}>{busy?'جارٍ الدخول...':'دخول لوحة التحكم'} <ArrowLeft size={17}/></button></form><button type="button" className="back-link centered" onClick={()=>{setNotice('');setView('password-recovery')}}>نسيت كلمة المرور؟</button><button type="button" className="back-link centered" onClick={()=>{setNotice('');setRegisterPassword('');setRegisterConfirmPassword('');setView('admin-register')}}>تسجيل جديد</button><button type="button" className="back-link centered" onClick={()=>setView('home')}>العودة للموقع</button></div></main>}

    {view==='admin-register'&&<main className="admin-login-view"><div className="admin-login-card"><div className="admin-lock"><Users size={27}/></div><div className="eyebrow">إنشاء حساب مؤقت</div><h1>تسجيل <span>حساب جديد</span></h1><p>أنشئ حسابًا بالبريد وكلمة المرور. التسجيل وحده لا يمنح صلاحية المشرف؛ سنفعّلها بأمان ثم نزيل هذا الخيار.</p><form onSubmit={registerAdminAccount}>
      <label>البريد الإلكتروني<div className="input-wrap"><Users size={17}/><input type="email" value={adminEmail} onChange={e=>setAdminEmail(e.target.value)} placeholder="أدخل بريدك الإلكتروني" autoComplete="email" required/></div></label>
      <label>كلمة المرور<div className="input-wrap"><KeyRound size={17}/><input type="password" value={registerPassword} onChange={e=>setRegisterPassword(e.target.value)} placeholder="8 أحرف على الأقل" autoComplete="new-password" minLength={8} required/></div></label>
      <label>تأكيد كلمة المرور<div className="input-wrap"><KeyRound size={17}/><input type="password" value={registerConfirmPassword} onChange={e=>setRegisterConfirmPassword(e.target.value)} placeholder="أعد كتابة كلمة المرور" autoComplete="new-password" minLength={8} required/></div></label>
      <button className="btn btn-gold join-submit" disabled={busy}>{busy?'جارٍ إنشاء الحساب...':'إنشاء الحساب'} <ArrowLeft size={17}/></button></form><button type="button" className="back-link centered" onClick={()=>{setNotice('');setView('admin-login')}}>العودة لتسجيل الدخول</button></div></main>}

    {view==='password-recovery'&&<main className="admin-login-view"><div className="admin-login-card"><div className="admin-lock"><KeyRound size={27}/></div><div className="eyebrow">استعادة الحساب</div><h1>نسيت <span>كلمة المرور؟</span></h1><p>أدخل بريد المشرف لإرسال رابط استعادة جديد.</p><form onSubmit={requestPasswordRecovery}>
      <label>البريد الإلكتروني<div className="input-wrap"><Users size={17}/><input type="email" value={adminEmail} onChange={e=>setAdminEmail(e.target.value)} placeholder="البريد المسجل للمشرف" required/></div></label>
      <button className="btn btn-gold join-submit" disabled={busy}>{busy?'جارٍ الإرسال...':'إرسال رابط الاستعادة'} <ArrowLeft size={17}/></button></form><button className="back-link centered" onClick={()=>{setNotice('');setView('admin-login')}}>العودة لتسجيل الدخول</button></div></main>}

    {view==='reset-password'&&<main className="admin-login-view"><div className="admin-login-card"><div className="admin-lock"><LockKeyhole size={27}/></div><div className="eyebrow">تأكيد الاستعادة</div><h1>تغيير <span>كلمة المرور</span></h1><p>اختر كلمة مرور جديدة لحساب المشرف.</p><form onSubmit={saveNewPassword}>
      <label>كلمة المرور الجديدة<div className="input-wrap"><KeyRound size={17}/><input type="password" autoComplete="new-password" value={newPassword} onChange={e=>setNewPassword(e.target.value)} minLength={8} placeholder="8 أحرف على الأقل" required/></div></label>
      <label>تأكيد كلمة المرور<div className="input-wrap"><KeyRound size={17}/><input type="password" autoComplete="new-password" value={confirmPassword} onChange={e=>setConfirmPassword(e.target.value)} minLength={8} placeholder="أعد كتابة كلمة المرور" required/></div></label>
      <button className="btn btn-gold join-submit" disabled={busy}>{busy?'جارٍ الحفظ...':'حفظ كلمة المرور الجديدة'} <Check size={17}/></button></form></div></main>}

    {view==='admin'&&<main className="admin-view"><div className="admin-title-row"><div><div className="eyebrow"><ShieldCheck size={15}/> إدارة المسابقة</div><h1>لوحة <span>المشرف</span></h1><p>أنت تتحكم بالأسئلة والتلميحات والمراحل والأسر وحالة المسابقة.</p></div><button className="btn btn-ghost" onClick={adminLogout}>تسجيل الخروج</button></div>
      <section className="panel admin-stage-panel control-panel"><h2>حالة المسابقة</h2><p>أوقف اللعب مؤقتًا أو أعد تشغيله؛ ستظل الأسر قادرة على الدخول إلى حساباتها.</p><div className="admin-control-row"><span className={'status-tag '+(gameSettings.is_open?'current':'')}>{gameSettings.is_open?'المسابقة مفتوحة':'المسابقة مغلقة'}</span><button className="btn btn-gold" onClick={async()=>{const next=!gameSettings.is_open;const {error}=await supabase.from('game_settings').update({is_open:next}).eq('id',true);if(error){setNotice('تعذر تغيير حالة المسابقة. تحقق من صلاحيات المشرف.');return;}setGameSettings(v=>({...v,is_open:next}));setGameOpen(next);setNotice(next?'تم فتح المسابقة.':'تم إيقاف المسابقة؛ يمكن للأسر الدخول وستظهر لهم شاشة التوقف.');}}>{gameSettings.is_open?'إغلاق المسابقة':'فتح المسابقة'}</button></div></section>
      <div className="admin-metrics"><div className="panel metric"><Users/><span>الفرق الظاهرة</span><strong>{teams.length}</strong></div><div className="panel metric"><BookOpen/><span>إجمالي المراحل</span><strong>{stages.length}</strong></div><div className="panel metric"><BadgeCheck/><span>مراحل مكتملة</span><strong>{completed}</strong></div></div>
      <section className="panel admin-stage-panel family-code-panel"><h2>إنشاء رمز دخول لأسرة</h2><p>رمز خاص بالأسرة، ويرتبط بأول جوال يدخل به. يُمنع أي جوال آخر من استخدام الرمز، حتى لو كان صحيحًا. يُحفظ الرمز كبصمة مشفّرة ولا يمكن عرضه مجددًا بعد إغلاق نافذة الإنشاء.</p><form onSubmit={createFamilyCode} className="admin-stage-form family-code-form"><label>اسم الأسرة<input value={familyName} onChange={e=>setFamilyName(e.target.value)} placeholder="مثال: أسرة أحمد" minLength={2} maxLength={80} required/></label><label>لون الأسرة<select value={familyColor} onChange={e=>setFamilyColor(e.target.value)}><option value="white">الأبيض — السؤال الأول</option><option value="blue">الأزرق — السؤال الثاني</option><option value="yellow">الأصفر — السؤال الثالث</option></select></label><button className="btn btn-gold" type="submit"><KeyRound size={17}/> إنشاء رمز الأسرة</button></form>{newFamilyCode&&<div className="generated-code" role="status"><span>رمز الأسرة — اللون {familyColorLabels[familyColor]} — انسخه وأرسله الآن</span><strong dir="ltr">{newFamilyCode}</strong><button type="button" className="btn btn-ghost" onClick={()=>navigator.clipboard?.writeText(newFamilyCode).then(()=>setNotice('تم نسخ رمز الأسرة.')).catch(()=>setNotice('انسخ الرمز يدويًا.'))}>نسخ الرمز</button></div>}</section>
      <section className="panel admin-stage-panel"><h2>إضافة مرحلة جديدة</h2><p>أنشئ المرحلة بعنوانها فقط، وبعدها احفظ التلميح أو السؤال أو الإجابة أو الحل النهائي كل واحد لحاله. تقدر تطلع وترجع أنت أو شخص ثاني بنفس حساب المشرف، وبتلقى كل شيء محفوظ. تبقى المرحلة مقفلة عن الأسر حتى تكتمل بيانات الأسئلة الثلاثة.</p><form onSubmit={createStage} className="admin-stage-form">
        <label>عنوان المرحلة<input value={newTitle} onChange={e=>setNewTitle(e.target.value)} placeholder="مثال: سر البوصلة" required/></label><label>وصف مختصر<input value={newDescription} onChange={e=>setNewDescription(e.target.value)} placeholder="وصف مختصر (اختياري)"/></label>
        <button className="btn btn-gold" type="submit" disabled={busy}>{busy?<RefreshCw className="spin" size={17}/>:<Check size={17}/>} إنشاء مسودة المرحلة</button></form>
        <div className="admin-list">{adminStages.map((s,i)=><div className="admin-stage-row" key={s.id}><span>{s.number||String(i+1).padStart(2,'0')}</span><div><strong>{s.title}</strong><small>{s.description||'مرحلة في المسابقة'}</small></div><span className="status-tag">تقدّم تلقائي</span><button className="btn btn-ghost btn-small" onClick={()=>setEditStage({...s,newAnswer:s.answer_text||'',newFinalAnswer:s.final_answer_text||'',questions:(s.questions||[]).map(q=>({...q,newAnswer:q.answer_text||'',newFinalAnswer:q.final_answer_text||''}))})}>تعديل</button><button className="btn btn-ghost btn-small danger" onClick={async()=>{if(!window.confirm('هل تريد حذف هذه المرحلة نهائيًا؟ سيتم حذف إجاباتها المسجلة أيضًا.'))return;const {error}=await supabase.from('stages').delete().eq('id',s.id);if(error){setNotice('تعذر حذف المرحلة.');return;}setNotice('تم حذف المرحلة وإجاباتها المرتبطة.');await refreshAdminData();}}>حذف</button></div>)}</div></section>
      <section className="panel admin-stage-panel"><h2>إدارة الأسر والفرق</h2><p>استبعاد الأسرة يعطّل رمزها وجلسة فريقها ويزيل الفريق من لوحة الترتيب، مع الاحتفاظ بسجله للمراجعة.</p><div className="admin-list">{familyCodes.map(fc=>{const t=adminTeams.find(x=>x.id===fc.used_by_team);return <div className="admin-stage-row family-row" key={fc.id}><div><strong>{fc.family_name}</strong><small>{t?`الفريق: ${t.name} • ${t.points||0} نقطة`:'لم تدخل الأسرة بعد'}</small></div><span className={`family-color-tag color-${fc.color||'white'}`}><i/> اللون {familyColorLabels[fc.color]||'الأبيض'}</span><span className={'status-tag '+(fc.is_active?'current':'')}>{!fc.is_active?'مستبعدة':t&&!t.is_active?'الفريق معطّل':t?'مشاركة':'رمز فعّال'}</span>{fc.is_active&&<button className="btn btn-ghost btn-small danger" onClick={async()=>{if(!window.confirm(`استبعاد ${fc.family_name} من المسابقة؟`))return;const {error:codeError}=await supabase.from('family_codes').update({is_active:false}).eq('id',fc.id);if(codeError){setNotice('تعذر تعطيل رمز الأسرة.');return;}if(fc.used_by_team){const {error:teamError}=await supabase.from('teams').update({is_active:false}).eq('id',fc.used_by_team);if(teamError){setNotice('تعطّل رمز الأسرة، لكن تعذّر تعطيل الفريق. حدّث الصفحة وحاول مرة أخرى.');await refreshAdminData();return;}}setNotice('تم استبعاد الأسرة وتعطيل جلستها.');await refreshAdminData();}}>استبعاد الأسرة</button>}</div>})}{!familyCodes.length&&<p className="empty-state">لا توجد أسر حتى الآن. أنشئ رمزًا لكل أسرة من القسم أعلاه.</p>}</div></section>
      {editStage&&<div className="edit-overlay"><section className="panel edit-stage-card"><div className="section-title-row"><h2>تعديل المرحلة والأسئلة</h2><button className="btn btn-ghost btn-small" onClick={()=>setEditStage(null)}>إغلاق</button></div><div className="admin-stage-form admin-stage-form-expanded"><label>عنوان المرحلة<input value={editStage.title} onChange={e=>setEditStage(v=>({...v,title:e.target.value}))} required/></label><label>وصف مختصر<input value={editStage.description||''} onChange={e=>setEditStage(v=>({...v,description:e.target.value}))}/></label>{(editStage.questions||[]).map((q,i)=><div className="question-editor" key={q.id||i}><h3>نسخة السؤال {q.variant_no}</h3><div className="field-group"><label>نص السؤال<textarea value={q.prompt} onChange={e=>setEditStage(v=>({...v,questions:v.questions.map((item,j)=>j===i?({...item,prompt:e.target.value}):item)}))}/></label><button type="button" className="btn btn-ghost btn-small" disabled={savingField===q.id+':prompt'} onClick={()=>saveQuestionField(i,'prompt')}>{savingField===q.id+':prompt'?'جارٍ الحفظ...':'حفظ نص السؤال فقط'}</button></div><div className="field-group"><label>الإجابة الصحيحة (ظاهرة للمشرف فقط)<input value={q.newAnswer||''} onChange={e=>setEditStage(v=>({...v,questions:v.questions.map((item,j)=>j===i?({...item,newAnswer:e.target.value}):item)}))} placeholder="الإجابة الصحيحة لهذا السؤال"/></label><button type="button" className="btn btn-ghost btn-small" disabled={savingField===q.id+':answer'} onClick={()=>saveQuestionField(i,'answer')}>{savingField===q.id+':answer'?'جارٍ الحفظ...':'حفظ الإجابة فقط'}</button></div><div className="field-group"><label>التلميح<textarea value={q.hint||''} onChange={e=>setEditStage(v=>({...v,questions:v.questions.map((item,j)=>j===i?({...item,hint:e.target.value}):item)}))}/></label><button type="button" className="btn btn-ghost btn-small" disabled={savingField===q.id+':hint'} onClick={()=>saveQuestionField(i,'hint')}>{savingField===q.id+':hint'?'جارٍ الحفظ...':'حفظ التلميح فقط'}</button></div><div className="field-group"><label>الحل النهائي الصحيح (ظاهر للمشرف فقط)<input value={q.newFinalAnswer||''} onChange={e=>setEditStage(v=>({...v,questions:v.questions.map((item,j)=>j===i?({...item,newFinalAnswer:e.target.value}):item)}))} placeholder="الحل الذي يجب أن تكتبه الأسرة"/></label><button type="button" className="btn btn-ghost btn-small" disabled={savingField===q.id+':finalAnswer'} onClick={()=>saveQuestionField(i,'finalAnswer')}>{savingField===q.id+':finalAnswer'?'جارٍ الحفظ...':'حفظ الحل النهائي فقط'}</button></div><div className="field-group"><label>النقاط<input type="number" min="0" max="10000" value={q.points_reward} onChange={e=>setEditStage(v=>({...v,questions:v.questions.map((item,j)=>j===i?({...item,points_reward:e.target.value}):item)}))}/></label><button type="button" className="btn btn-ghost btn-small" disabled={savingField===q.id+':points'} onClick={()=>saveQuestionField(i,'points')}>{savingField===q.id+':points'?'جارٍ الحفظ...':'حفظ النقاط فقط'}</button></div></div>)}<button type="button" className="btn btn-gold" onClick={async()=>{if(!editStage.title.trim()){setNotice('اكتب عنوان المرحلة أولًا.');return;}const {error:stageError}=await supabase.from('stages').update({title:editStage.title.trim(),description:editStage.description||''}).eq('id',editStage.id);if(stageError){setNotice(`تعذر حفظ عنوان ووصف المرحلة: ${stageError.message}`);return;}setNotice('تم حفظ عنوان ووصف المرحلة فقط؛ حقول الأسئلة لم تتغير.');await refreshAdminData();}}><Check size={17}/> حفظ عنوان ووصف المرحلة فقط</button></div></section></div>}</main>}

    {welcomeOpen&&<div className="welcome-overlay" role="dialog" aria-modal="true" aria-labelledby="welcome-title"><section className="welcome-card"><div className="welcome-emblem"><Sparkles size={28}/></div><p className="eyebrow">مجموعة ذو النورين</p><h2 id="welcome-title">مرحبًا وشرفتوا موقع ذو النورين</h2><p>يا هلا فيكم! نورتوا الموقع، ويارب تفوزون بالمسابقة وتستمتعون بالتحدي.</p><button className="btn btn-gold" onClick={closeWelcome}>يلا نبدأ <ArrowLeft size={17}/></button></section></div>}
    <footer className="footer"><Brand/><div className="footer-center">صُمّم للمغامرين وأصحاب العقول الفضولية</div><div className="footer-right"><span><ShieldCheck size={14}/> تجربة آمنة</span><span>© {new Date().getFullYear()} شفرة ذو النورين</span></div></footer>
  </div>
}