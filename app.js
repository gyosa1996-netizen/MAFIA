
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

const $ = (id) => document.getElementById(id);
const cfg = window.MAFIA_CONFIG || {};
const configured =
  cfg.SUPABASE_URL &&
  cfg.SUPABASE_KEY &&
  !cfg.SUPABASE_URL.includes("YOUR_PROJECT") &&
  !cfg.SUPABASE_KEY.includes("YOUR_");

let sb = null;
let mode = null;
let roomId = null;
let playerId = null;
let playerToken = null;
let hostToken = null;
let realtimeChannel = null;
let pollTimer = null;
let lastPhase = null;
let selectedTarget = null;
let lastActionPhase = null;
let bgmEnabled = true;

const phaseMeta = {
  lobby: ["⌛","대기실","참가자를 기다리는 중입니다."],
  night: ["🌙","밤이 되었습니다","모두 눈을 감고 역할 행동을 준비합니다."],
  mafia: ["🔪","마피아 차례","마피아는 공격할 대상을 선택합니다."],
  police: ["👮","경찰 차례","경찰은 조사할 대상을 선택합니다."],
  doctor: ["🩺","의사 차례","의사는 치료할 대상을 선택합니다."],
  morning: ["☀️","아침","밤사이 일어난 결과가 발표됩니다."],
  discussion: ["💬","낮 토론","누가 마피아인지 토론합니다."],
  vote: ["🗳️","투표","가장 의심되는 사람에게 투표합니다."],
  result: ["📣","투표 결과","투표 결과를 확인합니다."]
};
const roleMeta = {
  "마피아": ["role-mafia","밤에 시민을 공격합니다."],
  "경찰": ["role-police","밤에 한 명을 조사해 마피아 여부를 확인합니다."],
  "의사": ["role-doctor","밤에 한 명을 치료해 공격에서 보호합니다."],
  "시민": ["role-citizen","토론과 투표로 마피아를 찾아냅니다."]
};

function message(el, text, type="notice"){
  el.innerHTML = text ? `<div class="${type}">${text}</div>` : "";
}
function safeText(v){ return String(v ?? ""); }

function saveSession(){
  localStorage.setItem("mafia_session", JSON.stringify({mode,roomId,playerId,playerToken,hostToken}));
}
function loadSession(){
  try{
    const x = JSON.parse(localStorage.getItem("mafia_session") || "null");
    if(!x) return false;
    mode=x.mode; roomId=x.roomId; playerId=x.playerId; playerToken=x.playerToken; hostToken=x.hostToken;
    return !!roomId && (mode==="host" ? !!hostToken : !!playerId && !!playerToken);
  }catch{return false}
}
function clearSession(){
  localStorage.removeItem("mafia_session");
  location.href = location.pathname;
}

function setConnected(ok){
  $("connectionStatus").classList.toggle("online", !!ok);
  $("connectionStatus").textContent = ok ? "Supabase 연결됨" : "연결 확인 중";
}

async function rpc(name, args={}){
  const { data, error } = await sb.rpc(name,args);
  if(error) throw new Error(error.message || "요청 실패");
  return data;
}

function renderPlayers(el, players){
  el.innerHTML="";
  (players||[]).forEach(p=>{
    const div=document.createElement("div");
    div.className="player"+(p.alive ? "" : " dead");
    const name=document.createElement("span");
    name.textContent=p.name;
    const badge=document.createElement("span");
    badge.className="badge "+(p.alive?"alive":"dead");
    badge.textContent=p.alive?"생존":"사망";
    div.append(name,badge); el.appendChild(div);
  });
}

function renderPhase(el, phase, round){
  const m=phaseMeta[phase] || ["🎲",phase,""];
  el.innerHTML=`<div class="icon">${m[0]}</div><h2>${m[1]}</h2><p>${round ? `${round}라운드 · ` : ""}${m[2]}</p>`;
}

function currentCounts(){
  const vals=["mafiaCount","policeCount","doctorCount","citizenCount"].map(id=>Math.max(0,Number($(id).value)||0));
  return {mafia:vals[0],police:vals[1],doctor:vals[2],citizen:vals[3],total:vals.reduce((a,b)=>a+b,0)};
}
function updateCapacity(){
  const c=currentCounts();
  $("capacityInfo").textContent=`총 ${c.total}명 · 마피아 ${c.mafia} / 경찰 ${c.police} / 의사 ${c.doctor} / 시민 ${c.citizen}`;
}
["mafiaCount","policeCount","doctorCount","citizenCount"].forEach(id=>$(id).addEventListener("input",updateCapacity));
updateCapacity();

$("showCreateBtn").onclick=()=>{$("createPanel").classList.toggle("hidden");$("joinPanel").classList.add("hidden")};
$("showJoinBtn").onclick=()=>{$("joinPanel").classList.toggle("hidden");$("createPanel").classList.add("hidden")};

const qCode=new URLSearchParams(location.search).get("room");
if(qCode){
  $("roomCodeInput").value=qCode.replace(/\D/g,"").slice(0,5);
  $("joinPanel").classList.remove("hidden");
}

$("createRoomBtn").onclick=async()=>{
  const c=currentCounts();
  message($("homeMessage"),"");
  if(c.total<4 || c.mafia<1){
    message($("homeMessage"),"총 4명 이상, 마피아 1명 이상으로 설정하세요.","notice error"); return;
  }
  try{
    const data=await rpc("create_room",{p_mafia:c.mafia,p_police:c.police,p_doctor:c.doctor,p_citizen:c.citizen});
    mode="host";roomId=data.room_id;hostToken=data.host_token;playerId=null;playerToken=null;
    saveSession(); await enterHost();
  }catch(e){message($("homeMessage"),safeText(e.message),"notice error")}
};

$("joinRoomBtn").onclick=async()=>{
  const code=$("roomCodeInput").value.replace(/\D/g,"").slice(0,5);
  const name=$("playerNameInput").value.trim();
  message($("homeMessage"),"");
  if(code.length!==5 || !name){message($("homeMessage"),"방 코드 5자리와 이름을 입력하세요.","notice error");return}
  try{
    const data=await rpc("join_room",{p_code:code,p_name:name});
    mode="player";roomId=data.room_id;playerId=data.player_id;playerToken=data.player_token;hostToken=null;
    saveSession(); await enterPlayer();
  }catch(e){message($("homeMessage"),safeText(e.message),"notice error")}
};

async function publicState(){
  return await rpc("get_public_state",{p_room_id:roomId});
}
async function hostState(){
  return await rpc("get_host_state",{p_room_id:roomId,p_host_token:hostToken});
}
async function myState(){
  return await rpc("get_my_state",{p_player_id:playerId,p_player_token:playerToken});
}

function setupRealtime(){
  if(realtimeChannel) sb.removeChannel(realtimeChannel);
  realtimeChannel=sb.channel("room-"+roomId+"-"+Math.random().toString(36).slice(2))
    .on("postgres_changes",{event:"INSERT",schema:"public",table:"room_events",filter:`room_id=eq.${roomId}`},()=>refresh())
    .subscribe((status)=>setConnected(status==="SUBSCRIBED"));
  clearInterval(pollTimer);
  pollTimer=setInterval(refresh,2500);
}

async function enterHost(){
  $("homeScreen").classList.add("hidden");$("playerScreen").classList.add("hidden");$("hostScreen").classList.remove("hidden");
  setupRealtime(); await refreshHost();
}
async function enterPlayer(){
  $("homeScreen").classList.add("hidden");$("hostScreen").classList.add("hidden");$("playerScreen").classList.remove("hidden");
  setupRealtime(); await refreshPlayer();
}

async function refresh(){
  try{
    if(mode==="host") await refreshHost();
    if(mode==="player") await refreshPlayer();
  }catch(e){
    console.error(e);
    if(String(e.message).toLowerCase().includes("token")) clearSession();
  }
}

async function refreshHost(){
  const [pub,host]=await Promise.all([publicState(),hostState()]);
  setConnected(true);
  $("hostRoomCode").textContent=pub.room.code;
  renderPlayers($("hostPlayerList"),pub.players);
  renderPlayers($("hostAliveList"),pub.players);

  const inLobby=pub.room.status==="lobby";
  $("hostLobbyCard").classList.toggle("hidden",!inLobby);
  $("hostGameCard").classList.toggle("hidden",inLobby);

  if(inLobby){
    $("hostLobbyInfo").textContent=`${pub.players.length} / ${pub.room.capacity}명 참가 · 역할: 마피아 ${pub.room.mafia_count}, 경찰 ${pub.room.police_count}, 의사 ${pub.room.doctor_count}, 시민 ${pub.room.citizen_count}`;
    $("startGameBtn").disabled=pub.players.length!==pub.room.capacity;
    return;
  }

  renderPhase($("hostPhase"),pub.room.phase,pub.room.round);
  message($("hostAnnouncement"),pub.room.announcement ? `<b>${safeText(pub.room.announcement)}</b>`:"");
  const s=host.submissions;
  $("submissionGrid").innerHTML=[
    ["🔪 마피아",s.mafia_submitted,s.mafia_expected],
    ["👮 경찰",s.police_submitted,s.police_expected],
    ["🩺 의사",s.doctor_submitted,s.doctor_expected],
    ["🗳️ 투표",s.vote_submitted,s.vote_expected]
  ].map(x=>`<div class="submission">${x[0]}<b>${x[1]} / ${x[2]}</b></div>`).join("");

  const finished=pub.room.status==="finished";
  $("advanceBtn").classList.toggle("hidden",finished);
  $("rematchBtn").classList.toggle("hidden",!finished);
  if(finished && pub.room.winner){
    message($("hostAnnouncement"),`${pub.room.announcement ? `<b>${safeText(pub.room.announcement)}</b><br>`:""}<b>🏆 ${safeText(pub.room.winner)}</b>`,"notice success");
  }
  updateHostBgm(pub.room.phase, pub.room.status);
}

async function refreshPlayer(){
  const [pub,me]=await Promise.all([publicState(),myState()]);
  setConnected(true);
  $("playerRoomCode").textContent=pub.room.code;
  $("playerIdentity").textContent=`${me.name} 님`;
  renderPlayers($("playerLobbyList"),pub.players);
  renderPlayers($("playerAliveList"),pub.players);

  const inLobby=pub.room.status==="lobby";
  $("playerLobbyCard").classList.toggle("hidden",!inLobby);
  $("playerGameCard").classList.toggle("hidden",inLobby);
  if(inLobby) return;

  renderPhase($("playerPhase"),pub.room.phase,pub.room.round);
  message($("playerAnnouncement"),pub.room.announcement ? `<b>${safeText(pub.room.announcement)}</b>`:"");

  if(me.role){
    const meta=roleMeta[me.role]||["", ""];
    $("roleName").textContent=me.role;
    $("roleName").className="role-name "+meta[0];
    $("roleDescription").textContent=meta[1];
    if(me.role==="마피아" && me.mafia_team?.length){
      $("mafiaTeam").classList.remove("hidden");
      $("mafiaTeam").textContent="마피아 팀: "+me.mafia_team.map(x=>x.name).join(", ");
    }else $("mafiaTeam").classList.add("hidden");
  }

  if(pub.room.status==="finished"){
    message($("playerAnnouncement"),`${pub.room.announcement ? `<b>${safeText(pub.room.announcement)}</b><br>`:""}<b>🏆 ${safeText(pub.room.winner)}</b>`,"notice success");
  }

  renderAction(pub,me);
}

$("toggleRoleBtn").onclick=()=>{
  const showing=!$("roleShown").classList.contains("hidden");
  $("roleShown").classList.toggle("hidden",showing);
  $("roleHidden").classList.toggle("hidden",!showing);
  $("toggleRoleBtn").textContent=showing?"역할 보기":"역할 숨기기";
};

function renderAction(pub,me){
  const phase=pub.room.phase;
  if(lastActionPhase!==phase){
    selectedTarget=null;
    lastActionPhase=phase;
  }
  $("submitActionBtn").disabled=true;
  $("targetGrid").innerHTML="";
  message($("actionMessage"),"");
  $("investigationResult").classList.add("hidden");

  if(!me.alive || pub.room.status==="finished"){
    $("actionCard").classList.add("hidden"); return;
  }

  let allowed=false,title="",help="";
  if(phase==="mafia" && me.role==="마피아"){allowed=true;title="공격 대상 선택";help="마피아가 아닌 생존자 한 명을 선택하세요."}
  if(phase==="police" && me.role==="경찰"){allowed=true;title="조사 대상 선택";help="생존자 한 명을 조사하세요."}
  if(phase==="doctor" && me.role==="의사"){allowed=true;title="치료 대상 선택";help="이번 밤에 보호할 생존자 한 명을 선택하세요."}
  if(phase==="vote"){allowed=true;title="투표";help="가장 의심되는 생존자 한 명을 선택하세요."}

  $("actionCard").classList.toggle("hidden",!allowed);

  if(me.investigation && phase==="police"){
    $("investigationResult").classList.remove("hidden");
    $("investigationResult").innerHTML=`<strong>${safeText(me.investigation.target_name)}</strong><br>${me.investigation.is_mafia ? "🔴 마피아입니다." : "🔵 마피아가 아닙니다."}`;
  }

  if(!allowed) return;
  $("actionTitle").textContent=title;
  $("actionHelp").textContent=help;

  const mafiaIds=new Set((me.mafia_team||[]).map(x=>x.id));
  pub.players.filter(p=>p.alive).filter(p=>{
    if(phase==="mafia") return p.id!==me.id && !mafiaIds.has(p.id);
    if(phase==="police" || phase==="vote") return p.id!==me.id;
    return true; // doctor can save self
  }).forEach(p=>{
    const b=document.createElement("button");
    b.className="target";b.textContent=p.name;
    if(selectedTarget===p.id){
      b.classList.add("selected");
      $("submitActionBtn").disabled=false;
    }
    b.onclick=()=>{
      selectedTarget=p.id;
      document.querySelectorAll(".target").forEach(x=>x.classList.remove("selected"));
      b.classList.add("selected");$("submitActionBtn").disabled=false;
    };
    $("targetGrid").appendChild(b);
  });

  if(me.submitted_phase===phase){
    message($("actionMessage"),"이미 제출했습니다. 다시 선택해 제출하면 변경됩니다.","notice success");
  }
}

$("submitActionBtn").onclick=async()=>{
  if(!selectedTarget)return;
  try{
    const data=await rpc("submit_action",{p_player_id:playerId,p_player_token:playerToken,p_target_id:selectedTarget});
    message($("actionMessage"),"제출했습니다.","notice success");
    if(data?.investigation){
      $("investigationResult").classList.remove("hidden");
      $("investigationResult").innerHTML=`<strong>${safeText(data.investigation.target_name)}</strong><br>${data.investigation.is_mafia ? "🔴 마피아입니다." : "🔵 마피아가 아닙니다."}`;
    }
    await refreshPlayer();
  }catch(e){message($("actionMessage"),safeText(e.message),"notice error")}
};

$("startGameBtn").onclick=async()=>{
  if(bgmEnabled) playAudio(nightBgm);
  try{await rpc("host_start_game",{p_room_id:roomId,p_host_token:hostToken});await refreshHost()}
  catch(e){alert(e.message)}
};
$("advanceBtn").onclick=async()=>{
  try{await rpc("host_advance_phase",{p_room_id:roomId,p_host_token:hostToken});await refreshHost()}
  catch(e){alert(e.message)}
};
$("rematchBtn").onclick=async()=>{
  if(!confirm("같은 참가자로 역할을 다시 섞어 새 게임을 시작할까요?"))return;
  try{await rpc("host_rematch",{p_room_id:roomId,p_host_token:hostToken});await refreshHost()}
  catch(e){alert(e.message)}
};

$("copyCodeBtn").onclick=async()=>{
  const code=$("hostRoomCode").textContent.trim();
  try{await navigator.clipboard.writeText(code);$("copyCodeBtn").textContent="복사됨 ✓";setTimeout(()=>$("copyCodeBtn").textContent="방 코드 복사",1200)}
  catch{prompt("방 코드",code)}
};
$("hostResetSessionBtn").onclick=clearSession;
$("playerResetSessionBtn").onclick=clearSession;

const nightBgm=$("nightBgm"), dayBgm=$("dayBgm");
nightBgm.volume=1;dayBgm.volume=1;

async function playAudio(audio){
  if(!bgmEnabled)return;
  try{await audio.play()}catch(e){/* 첫 자동재생은 브라우저 정책상 막힐 수 있음 */}
}
function stopAudio(audio,rewind=true){audio.pause();if(rewind)audio.currentTime=0}
function updateHostBgm(phase,status){
  if(mode!=="host"){stopAudio(nightBgm);stopAudio(dayBgm);return}
  if(!bgmEnabled || status==="lobby"){stopAudio(nightBgm);stopAudio(dayBgm);return}
  const night=["night","mafia","police","doctor"].includes(phase);
  const day=["morning","discussion","vote","result"].includes(phase);
  if(night){stopAudio(dayBgm);playAudio(nightBgm)}
  else if(day){stopAudio(nightBgm);playAudio(dayBgm)}
  else{stopAudio(nightBgm);stopAudio(dayBgm)}
}
$("bgmToggleBtn").onclick=()=>{
  bgmEnabled=!bgmEnabled;
  $("bgmToggleBtn").textContent=bgmEnabled?"🔊 배경음 켜짐":"🔇 배경음 꺼짐";
  if(!bgmEnabled){stopAudio(nightBgm,false);stopAudio(dayBgm,false)}
  else refreshHost();
};
$("volumeSlider").oninput=(e)=>{
  const v=Number(e.target.value)/100;
  nightBgm.volume=v;dayBgm.volume=v;$("volumeValue").textContent=e.target.value+"%";
  if(v>0 && mode==="host") refreshHost();
};

// user gesture on host controls unlocks browser audio
document.addEventListener("click",()=>{
  if(mode==="host" && bgmEnabled && lastPhase===null){
    // no-op; the next refresh/phase change will play audio
  }
},{once:true});

async function boot(){
  if(!configured){
    $("configError").classList.remove("hidden");
    $("showCreateBtn").disabled=true;$("showJoinBtn").disabled=true;
    return;
  }
  sb=createClient(cfg.SUPABASE_URL,cfg.SUPABASE_KEY,{auth:{persistSession:false}});
  try{
    await rpc("mafia_ping");
    setConnected(true);
    if(loadSession()){
      if(mode==="host") await enterHost();
      else await enterPlayer();
    }
  }catch(e){
    console.error(e);clearSession();
  }
}
boot();
