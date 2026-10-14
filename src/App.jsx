import { useEffect, useMemo, useState } from 'react';
import { ArrowLeft, ArrowUpLeft, BadgeCheck, BookOpen, Check, ChevronLeft, CircleHelp, Clock3, Compass, Crown, Eye, EyeOff, Flag, KeyRound, Lightbulb, LockKeyhole, MapPin, Menu, Radio, RefreshCw, ShieldCheck, Sparkles, Swords, Trophy, Users, X, Zap } from 'lucide-react';
import { isSupabaseConfigured, supabase } from './lib/supabase.js';

const demoStages = [
  { id:'demo-1', title:'البداية', number:'01', description:'أول خيط في رحلة الكنز', status:'current', prompt:'تأمل المكان حولك. ابحث عن أول دليل مخبأ في بداية الرحلة، واجمع ملاحظات فريقك قبل الإجابة.', hint:'ابحث عن المكان الذي تبدأ منه كل حكاية.' },
  { id:'demo-2', title:'الأثر المفقود', number:'02', description:'اجمعوا الأدلة واربطوا بينها', status:'locked', hint:'الأثر لا يتكلم، لكن مكانه يدل عليه.' },
  { id:'demo-3', title:'شفرة الحارس', number:'03', description:'فكوا الرمز قبل بقية الفرق', status:'locked', hint:'أحيانًا تكون الإجابة أمام عينيك.' },
  { id:'demo-4', title:'الكنز الأخير', number:'04', description:'اقتربتم من خط النهاية', status:'locked', hint:'كل خطوة صحيحة تقربكم من الكنز.' }
];
const demoTeams = [
  {id:'t1',name:'الصقور',points:240,progress:3,color:'gold'},
  {id:'t2',name:'الذئاب',points:180,progress:2,color:'blue'},
  {id:'t3',name:'النمور',points:120,progress:1,color:'purple'}
];

function Brand(){return <div className="brand"><div className="brand-mark"><KeyRound size={22}/></div><div><strong>شفرة الكنز</strong><span>رحلة تبدأ بلغز</span></div></div>}

export default function App(){
  const [view,setView]=useState('home'),[teamName,setTeamName]=useState(''),[sessionCode,setSessionCode]=useState('');
  const [team,setTeam]=useState(null),[stages,setStages]=useState([]),[teams,setTeams]=useState([]),[gameOpen,setGameOpen]=useState(null);
  const [activeStage,setActiveStage]=useState(null),[answer,setAnswer]=useState(''),[feedback,setFeedback]=useState('');
  const [hintVisible,setHintVisible]=useState(false),[busy,setBusy]=useState(false),[notice,setNotice]=useState('');
  const [adminEmail,setAdminEmail]=useState(''),[adminPassword,setAdminPassword]=useState(''),[adminSession,setAdminSession]=useState(false);
  const [newTitle,setNewTitle]=useState(''),[newPrompt,setNewPrompt]=useState(''),[newAnswer,setNewAnswer]=useState('');
  const [familyName,setFamilyName]=useState(''),[newFamilyCode,setNewFamilyCode]=useState('');
  const [showPassword,setShowPassword]=useState(false);
  const completed=useMemo(()=>stages.filter(s=>s.status==='completed').length,[stages]);
  const currentStage=(activeStage&&stages.find(s=>s.id===activeStage.id))||stages.find(s=>s.status==='current')||null;

  async function refreshTeamState(token,{silent=false}={}){
    if(!isSupabaseConfigured||!token)return false;
    const {data,error}=await supabase.rpc('get_team_game_state',{p_session_token:token});
    if(error||!data?.success){
      if(!silent)setNotice(data?.message||'تعذر تحميل تقدم الفريق. حاول تسجيل الدخول من جديد.');
      localStorage.removeItem('shifrat-team-session');
      setTeam(null);
      return false;
    }
    setTeam({...data.team,token});
    setStages(Array.isArray(data.stages)?data.stages:[]);
    return true;
  }

  useEffect(()=>{
    if(!isSupabaseConfigured)return;
    supabase.auth.getSession().then(({data})=>{
      if(data.session?.user?.app_metadata?.role==='game_admin'){setAdminSession(true);setView(v=>v==='admin-login'?'admin':v);}
    });
    const {data:authListener}=supabase.auth.onAuthStateChange((_event,session)=>{
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
      if(b.data)setTeams(b.data.map((t,i)=>({...t,color:['gold','blue','purple'][i%3]})));
      const saved=localStorage.getItem('shifrat-team-session');
      if(saved){
        try{
          const session=JSON.parse(saved);
          if(session?.token&&await refreshTeamState(session.token,{silent:true}))return;
        }catch{}
      }
      if(a.data)setStages(a.data.map(s=>({...s,status:s.sort_order<=4?'current':'locked',prompt:null,hint:null})));
    }
    load();
    const ch=supabase.channel('game-public-updates')
      .on('postgres_changes',{event:'*',schema:'public',table:'stages'},load)
      .on('postgres_changes',{event:'*',schema:'public',table:'teams'},load).subscribe();
    return()=>{live=false;supabase.removeChannel(ch);authListener.subscription.unsubscribe()};
  },[]);

  async function joinGame(e){
    e.preventDefault();setNotice('');
    if(!teamName.trim()||!sessionCode.trim()){setNotice('أدخل اسم الفريق ورمز الدخول.');return}
    if(!isSupabaseConfigured){setNotice('الموقع غير متصل بقاعدة البيانات حاليًا. حاول لاحقًا.');return}
    if(gameOpen===false){setNotice('المسابقة مغلقة حاليًا. انتظر إعلان فتحها من المنظّم.');return}
    setBusy(true);
    const {data,error}=await supabase.rpc('join_game',{p_team_name:teamName.trim(),p_session_code:sessionCode.trim()});
    setBusy(false);
    if(error||!data?.success){setNotice(data?.message||'تعذر الدخول. تحقق من رمز الأسرة وحالة المسابقة.');return}
    const saved={id:data.team_id,name:data.team_name,token:data.session_token};
    localStorage.setItem('shifrat-team-session',JSON.stringify(saved));
    setTeam(saved);
    await refreshTeamState(data.session_token,{silent:true});
    setView('game');setActiveStage(null);setFeedback('');
  }

  async function submitAnswer(e){
    e.preventDefault();if(!answer.trim()||!currentStage)return;
    if(!team?.token||!currentStage||currentStage.status==='locked'||currentStage.status==='completed')return;
    setBusy(true);setFeedback('');
    const {data,error}=await supabase.rpc('submit_stage_answer',{p_session_token:team.token,p_stage_id:currentStage.id,p_answer:answer.trim()});
    setBusy(false);
    if(error){setFeedback('تعذر إرسال الإجابة الآن. تحقق من اتصال الإنترنت ثم حاول مجددًا.');return}
    setFeedback(data?.message||'تم استلام الإجابة.');
    if(data?.correct){setActiveStage(null);setAnswer('');}
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

  async function createFamilyCode(e){
    e.preventDefault();setNotice('');setNewFamilyCode('');
    if(!isSupabaseConfigured||!adminSession){setNotice('سجّل دخول المشرف أولًا.');return}
    if(familyName.trim().length<2){setNotice('اكتب اسم الأسرة (حرفان على الأقل).');return}
    const bytes=crypto.getRandomValues(new Uint8Array(6));
    const code=Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('').toUpperCase();
    const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(code.toLowerCase()));
    const codeHash=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('');
    const {data:userData}=await supabase.auth.getUser();
    const {error}=await supabase.from('family_codes').insert({family_name:familyName.trim(),code_hash:codeHash,created_by:userData.user?.id});
    if(error){setNotice('تعذر إنشاء الرمز. تأكد من تشغيل schema.sql ومن صلاحية المشرف.');return}
    setNewFamilyCode(code);setFamilyName('');setNotice('تم إنشاء رمز الأسرة. انسخه وأرسله للأسرة؛ لن يُعرض كاملًا مرة أخرى.');
  }

  async function hashAnswer(value){
    const bytes=new TextEncoder().encode(value.trim().toLowerCase());
    const digest=await crypto.subtle.digest('SHA-256',bytes);
    return Array.from(new Uint8Array(digest)).map(b=>b.toString(16).padStart(2,'0')).join('');
  }

  async function createStage(e){
    e.preventDefault();
    if(!newTitle.trim()||!newPrompt.trim()||!newAnswer.trim()){setNotice('أكمل جميع بيانات المرحلة.');return}
    if(!isSupabaseConfigured||!adminSession){setNotice('يلزم تسجيل دخول المشرف وربط Supabase لحفظ المرحلة.');return}
    const allCurrentStagesCompleted=stages.length>0&&stages.every(s=>s.status==='completed');
    const {error}=await supabase.from('stages').insert({title:newTitle.trim(),prompt:newPrompt.trim(),answer_hash:await hashAnswer(newAnswer),status:(stages.length===0||allCurrentStagesCompleted)?'current':'locked',sort_order:stages.length+1,description:'مرحلة جديدة'});
    if(error){setNotice('لم يتم حفظ المرحلة. تحقق من صلاحيات المشرف وترتيب المراحل.');return}
    setNewTitle('');setNewPrompt('');setNewAnswer('');setNotice('تمت إضافة المرحلة. إذا انتهت المراحل السابقة، فستكون هذه بداية المجموعة الجديدة.');
    const {data}=await supabase.from('public_stages').select('id,title,number,description,status,sort_order,points_reward').order('sort_order');
    if(data)setStages(data);
  }

  async function adminLogout(){if(supabase)await supabase.auth.signOut();setAdminSession(false);setView('home')}

  return <div className="app-shell">
    <header className="topbar"><Brand/><nav className="desktop-nav">
      <button className={view==='home'?'nav-link active':'nav-link'} onClick={()=>setView('home')}>الرئيسية</button>
      <button className={view==='leaderboard'?'nav-link active':'nav-link'} onClick={()=>setView('leaderboard')}>لوحة الترتيب</button>
      <button className="nav-link" onClick={()=>{setView('admin-login');setNotice('')}}>المشرف <LockKeyhole size={14}/></button>
    </nav><button className="mobile-menu" aria-label="القائمة" onClick={()=>setView(view==='admin-login'?'home':'admin-login')}><Menu/></button>
    <div className="live-pill"><span className="live-dot"/>{!isSupabaseConfigured?'وضع المعاينة':gameOpen===null?'جارٍ التحقق':gameOpen?'المسابقة مفتوحة':'المسابقة مغلقة'}</div></header>
    {notice&&<div className="notice" role="status"><span>{notice}</span><button onClick={()=>setNotice('')} aria-label="إغلاق"><X size={16}/></button></div>}

    {view==='home'&&<main>
      <section className="hero"><div className="hero-copy"><div className="eyebrow"><Sparkles size={15}/> تحدٍّ للعقول الشجاعة</div>
        <h1>كل لغز يقرّبك<br/><span>من الكنز.</span></h1>
        <p className="hero-description">كوّن فريقك، فك الشفرات، واتبع الأدلة. رحلة مليئة بالتحديات تنتظر من يملك عينًا تلاحظ وعقلًا يربط التفاصيل.</p>
        <div className="hero-actions"><button className="btn btn-gold" onClick={()=>document.getElementById('join-card')?.scrollIntoView({behavior:'smooth',block:'center'})}><Swords size={18}/> ابدأ المغامرة <ArrowLeft size={17}/></button><button className="btn btn-ghost" onClick={()=>setView('leaderboard')}>شاهد ترتيب الفرق <ChevronLeft size={17}/></button></div>
        <div className="hero-stats"><div><strong>{teams.length.toLocaleString('ar')}</strong><span>فرق مشاركة</span></div><i/><div><strong>{stages.length.toLocaleString('ar')}</strong><span>مراحل التحدي</span></div><i/><div><strong>{completed.toLocaleString('ar')}</strong><span>مراحل مكتملة</span></div></div>
      </div><div className="hero-art" aria-label="رسم توضيحي لصندوق كنز"><div className="orbit orbit-one"/><div className="orbit orbit-two"/><div className="star star-a">✦</div><div className="star star-b">✧</div><div className="star star-c">✦</div><div className="treasure-glow"/><div className="treasure-chest"><div className="chest-lid"><div className="chest-band"/></div><div className="chest-body"><div className="chest-band"/><div className="chest-lock"><KeyRound size={25}/></div></div><div className="chest-foot left"/><div className="chest-foot right"/></div><div className="floating-tag tag-top"><Compass size={15}/> اتبع الدليل</div><div className="floating-tag tag-bottom"><Zap size={15}/> فك الشفرة</div><div className="art-caption">الكنز لا يصل إليه إلا من يبحث</div></div></section>

      <section className="join-section" id="join-card"><div className="section-heading"><div className="section-icon"><KeyRound size={20}/></div><div><h2>ادخل إلى ساحة التحدي</h2><p>أدخل بيانات فريقك للانطلاق في الرحلة</p></div></div>
        <form className="join-form" onSubmit={joinGame}><label>اسم الفريق<div className="input-wrap"><Users size={18}/><input value={teamName} onChange={e=>setTeamName(e.target.value)} placeholder="مثال: صقور الصحراء" maxLength={50} required/></div></label>
        <label>رمز الدخول<div className="input-wrap"><KeyRound size={18}/><input value={sessionCode} onChange={e=>setSessionCode(e.target.value)} placeholder="أدخل الرمز الذي استلمته" maxLength={80} required/></div></label>
        <button className="btn btn-gold join-submit" disabled={busy}>{busy?<RefreshCw className="spin" size={18}/>:<ArrowUpLeft size={18}/>} {busy?'جارٍ التحقق...':'دخول الفريق'}</button></form>
        <div className="secure-note"><ShieldCheck size={15}/> رمز الدخول خاص بفريقك — لا تشاركه مع الفرق الأخرى</div></section>

      <section className="stages-section"><div className="section-title-row"><div><div className="eyebrow">خارطة الرحلة</div><h2>مراحل البحث عن الكنز</h2></div><span className="muted-label">{stages.length} مراحل</span></div>
        <div className="stage-grid">{stages.length?stages.map((s,i)=><button className={'stage-card '+s.status} key={s.id} onClick={()=>{if(s.status!=='locked'){setActiveStage(s);if(team)setView('game');else setNotice('ادخل بيانات فريقك أولًا لبدء المرحلة.')}}}>
          <div className="stage-card-top"><span className="stage-number">{s.number||String(i+1).padStart(2,'0')}</span>{s.status==='completed'?<BadgeCheck size={19}/>:s.status==='locked'?<LockKeyhole size={18}/>:<Radio size={18}/>}</div><h3>{s.title}</h3><p>{s.description||'اكتشف الدليل التالي في رحلتك'}</p><div className="stage-card-footer"><span>{s.status==='completed'?'مكتملة':s.status==='locked'?'مقفلة':'متاحة الآن'}</span><ChevronLeft size={16}/></div>
        </button>):<div className="empty-state">تُعرض مراحل البحث هنا بعد تجهيزها من منظّم المسابقة.</div>}</div></section>
      <section className="bottom-banner"><div className="banner-emblem"><Trophy size={27}/></div><div><h2>هل فريقك مستعد للتحدي؟</h2><p>كل ثانية تصنع فرقًا. وكل دليل يقربك من الفوز.</p></div><button className="btn btn-outline" onClick={()=>document.getElementById('join-card')?.scrollIntoView({behavior:'smooth',block:'center'})}>انطلق الآن <ArrowLeft size={16}/></button></section>
    </main>}

    {view==='game'&&<main className="game-view"><button className="back-link" onClick={()=>setView('home')}><ArrowLeft size={16}/> العودة للرئيسية</button>
      <div className="game-header"><div><div className="eyebrow"><Radio size={14}/> ساحة التحدي</div><h1>حيّاكم يا <span>{team?.name||teamName}</span></h1><p>ركزوا مع بعض، كل تفصيلة ممكن تكون المفتاح.</p></div><div className="team-badge"><Users size={17}/><span>فريق مشارك</span></div></div>
      <div className="game-layout"><section className="panel puzzle-panel"><div className="panel-kicker"><span className="puzzle-icon"><CircleHelp size={22}/></span><span>{currentStage?.status==='completed'?'مرحلة مكتملة':'المرحلة المختارة'} <b>{currentStage?.number||'—'}</b></span></div>
        <h2>{currentStage?.title||(stages.length?'أكملتم المراحل المتاحة!':'الرحلة تستعد للانطلاق')}</h2><p className="puzzle-prompt">{currentStage?.prompt||(stages.length?'ترقّبوا إضافة المراحل التالية من منظّم المسابقة.':'لم تُضف مراحل المسابقة بعد. ارجعوا قريبًا لبدء المغامرة.')}</p>
        <button className="hint-toggle" onClick={()=>setHintVisible(v=>!v)}>{hintVisible?<EyeOff size={16}/>:<Lightbulb size={16}/>} {hintVisible?'إخفاء التلميح':'اطلب تلميحًا'} <ChevronLeft size={15}/></button>
        {hintVisible&&<div className="hint-box"><Lightbulb size={17}/><span>{currentStage?.hint||'راقب التفاصيل الصغيرة، فقد تقودك إلى الإجابة.'}</span></div>}
        <form className="answer-form" onSubmit={submitAnswer}><label htmlFor="answer">إجابة فريقك</label><div className="input-wrap answer-input"><input id="answer" value={answer} onChange={e=>setAnswer(e.target.value)} placeholder={currentStage?.status==='completed'?'هذه المرحلة مكتملة':'اكتب الإجابة هنا...'} maxLength={200} disabled={!currentStage||currentStage.status!=='current'||busy} required/><button className="answer-send" disabled={busy||!currentStage||currentStage.status!=='current'}>{busy?<RefreshCw className="spin" size={18}/>:<ArrowLeft size={18}/>}</button></div><p className="answer-help"><LockKeyhole size={13}/> {currentStage?.status==='completed'?'أنجزتم هذه المرحلة بالفعل. اختاروا مرحلة متاحة أخرى.':!currentStage?'أكملتم كل المراحل المتاحة حاليًا.': 'إجاباتكم خاصة بفريقكم ولا تظهر للفرق الأخرى.'}</p></form>
        {feedback&&<div className="feedback" role="status">{feedback}</div>}</section>
        <aside className="panel progress-panel"><h3><Flag size={18}/> تقدم الفريق</h3><div className="progress-number"><strong>{completed}</strong><span>من {stages.length} مراحل</span></div><div className="progress-track"><span style={{width:(stages.length?completed/stages.length*100:0)+'%'}}/></div>
          <div className="mini-stage-list">{stages.map((s,i)=><button key={s.id} className={'mini-stage '+s.status} onClick={()=>{if(s.status!=='locked')setActiveStage(s)}}><span className="mini-stage-dot">{s.status==='completed'?<Check size={13}/>:i+1}</span><span>{s.title}</span>{s.status==='locked'&&<LockKeyhole size={14}/>}</button>)}</div>
          <div className="progress-tip"><Sparkles size={16}/><p>تعاونوا ودوّنوا كل دليل؛ التفاصيل الصغيرة قد تصنع الفارق.</p></div></aside></div></main>}

    {view==='leaderboard'&&<main className="leaderboard-view"><button className="back-link" onClick={()=>setView('home')}><ArrowLeft size={16}/> العودة للرئيسية</button><div className="leaderboard-hero"><div className="eyebrow"><Trophy size={15}/> المنافسة تحتدم</div><h1>لوحة <span>الأبطال</span></h1><p>كل خطوة محسوبة، وكل فريق يكتب حكايته.</p></div><section className="panel leaderboard-panel"><div className="leaderboard-head"><h2><Crown size={20}/> ترتيب الفرق</h2><span className="live-pill"><span className="live-dot"/> مباشر</span></div>
      {[...teams].sort((a,b)=>b.points-a.points).map((t,i)=><div className={'leader-row '+(i===0?'first':'')} key={t.id}><span className={'rank rank-'+(i+1)}>{i===0?<Crown size={17}/>:String(i+1).padStart(2,'0')}</span><div className={'team-avatar '+(t.color||'blue')}>{(t.name||'?').slice(0,1)}</div><div className="leader-team"><strong>{t.name}</strong><span>{t.progress||0} مراحل مكتملة</span></div><div className="leader-points"><strong>{Number(t.points||0).toLocaleString('ar')}</strong><span>نقطة</span></div><div className="leader-progress"><span style={{width:Math.min(100,(t.progress||0)/Math.max(1,stages.length)*100)+'%'}}/></div></div>)}
      {!teams.length&&<p className="empty-state">ستظهر الفرق هنا عند بدء المسابقة.</p>}</section></main>}

    {view==='admin-login'&&<main className="admin-login-view"><div className="admin-login-card"><div className="admin-lock"><LockKeyhole size={27}/></div><div className="eyebrow">منطقة محمية</div><h1>دخول <span>المشرف</span></h1><p>سجّل الدخول لإدارة مراحل المسابقة والفرق.</p><form onSubmit={adminLogin}>
      <label>البريد الإلكتروني<div className="input-wrap"><Users size={17}/><input type="email" value={adminEmail} onChange={e=>setAdminEmail(e.target.value)} placeholder="admin@example.com" required/></div></label>
      <label>كلمة المرور<div className="input-wrap"><KeyRound size={17}/><input type={showPassword?'text':'password'} value={adminPassword} onChange={e=>setAdminPassword(e.target.value)} placeholder="كلمة المرور" required/><button type="button" className="field-action" onClick={()=>setShowPassword(v=>!v)}>{showPassword?<EyeOff size={17}/>:<Eye size={17}/>}</button></div></label>
      <button className="btn btn-gold join-submit" disabled={busy}>{busy?'جارٍ الدخول...':'دخول لوحة التحكم'} <ArrowLeft size={17}/></button></form><button className="back-link centered" onClick={()=>setView('home')}>العودة للموقع</button></div></main>}

    {view==='admin'&&<main className="admin-view"><div className="admin-title-row"><div><div className="eyebrow"><ShieldCheck size={15}/> إدارة المسابقة</div><h1>لوحة <span>المشرف</span></h1><p>إدارة المراحل وإعدادات رحلة الكنز.</p></div><button className="btn btn-ghost" onClick={adminLogout}>تسجيل الخروج</button></div>
      <div className="admin-metrics"><div className="panel metric"><Users/><span>الفرق الظاهرة</span><strong>{teams.length}</strong></div><div className="panel metric"><BookOpen/><span>إجمالي المراحل</span><strong>{stages.length}</strong></div><div className="panel metric"><BadgeCheck/><span>مراحل مكتملة</span><strong>{completed}</strong></div></div>
      <section className="panel admin-stage-panel family-code-panel"><h2>إنشاء رمز دخول لأسرة</h2><p>رمز خاص بالأسرة؛ يمكنهم استخدامه مجددًا باسم الفريق نفسه. يُحفظ الرمز كبصمة مشفّرة ولا يمكن عرضه مجددًا بعد إغلاق نافذة الإنشاء.</p><form onSubmit={createFamilyCode} className="admin-stage-form family-code-form"><label>اسم الأسرة<input value={familyName} onChange={e=>setFamilyName(e.target.value)} placeholder="مثال: أسرة أحمد" minLength={2} maxLength={80} required/></label><button className="btn btn-gold" type="submit"><KeyRound size={17}/> إنشاء رمز الأسرة</button></form>{newFamilyCode&&<div className="generated-code" role="status"><span>رمز الأسرة — انسخه وأرسله الآن</span><strong dir="ltr">{newFamilyCode}</strong><button type="button" className="btn btn-ghost" onClick={()=>navigator.clipboard?.writeText(newFamilyCode).then(()=>setNotice('تم نسخ رمز الأسرة.')).catch(()=>setNotice('انسخ الرمز يدويًا.'))}>نسخ الرمز</button></div>}</section>
      <section className="panel admin-stage-panel"><h2>إضافة مرحلة جديدة</h2><p>تُحفظ الإجابة كبصمة SHA-256 ولا تظهر في واجهة المشاركين.</p><form onSubmit={createStage} className="admin-stage-form">
        <label>عنوان المرحلة<input value={newTitle} onChange={e=>setNewTitle(e.target.value)} placeholder="مثال: سر البوصلة" required/></label><label>نص اللغز<input value={newPrompt} onChange={e=>setNewPrompt(e.target.value)} placeholder="اكتب نص اللغز" required/></label><label>الإجابة الصحيحة<input value={newAnswer} onChange={e=>setNewAnswer(e.target.value)} placeholder="لن تظهر للمشاركين" required/></label><button className="btn btn-gold" type="submit"><Check size={17}/> حفظ المرحلة</button></form>
        <div className="admin-list">{stages.map((s,i)=><div className="admin-stage-row" key={s.id}><span>{s.number||String(i+1).padStart(2,'0')}</span><div><strong>{s.title}</strong><small>{s.description||'مرحلة في المسابقة'}</small></div><span className={'status-tag '+s.status}>{s.status==='completed'?'مكتملة':s.status==='current'?'متاحة':'مقفلة'}</span></div>)}</div></section></main>}

    <footer className="footer"><Brand/><div className="footer-center">صُمّم للمغامرين وأصحاب العقول الفضولية</div><div className="footer-right"><span><ShieldCheck size={14}/> تجربة آمنة</span><span>© {new Date().getFullYear()} شفرة الكنز</span></div></footer>
  </div>
}