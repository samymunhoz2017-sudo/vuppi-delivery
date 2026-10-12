(function(){
  'use strict';
  const form=document.getElementById('portalLogin');
  const message=document.getElementById('portalMessage');
  const continueButton=document.getElementById('sessionContinue');
  const switchButton=document.getElementById('sessionSwitch');
  const sessionBox=document.getElementById('activeSession');
  const sessionEmail=document.getElementById('activeSessionEmail');
  const auth=UPAuthClient.create(UP_CONFIG);
  let activeUser=null;
  function say(text,type=''){message.textContent=text||'';message.dataset.type=type}
  async function destination(){
    const access=await auth.getAccess();
    if(Array.isArray(access)&&access.length)return '/admin';
    const response=await fetch('/api/delivery/state',{credentials:'same-origin',headers:{Accept:'application/json'}});
    const data=await response.json().catch(()=>({}));
    if(!response.ok)throw Error(data.message||'Não foi possível identificar seu perfil.');
    if(data.admin)return '/admin';
    if(data.profile?.kind==='merchant')return '/estabelecimento';
    if(data.profile?.kind==='courier')return '/entregador';
    throw Error('Seu acesso existe, mas ainda não possui um perfil ativo. Fale com a central.');
  }
  async function route(button){
    if(button)button.disabled=true;
    say('Identificando seu perfil…');
    try{location.replace(await destination())}
    catch(error){say(error.message||'Não foi possível abrir seu painel.','error');if(button)button.disabled=false}
  }
  function showSession(user){
    activeUser=user||null;
    sessionBox.hidden=!user;
    continueButton.hidden=!user;
    switchButton.hidden=!user;
    sessionEmail.textContent=user?.email||'';
  }
  form.onsubmit=async event=>{
    event.preventDefault();
    const button=form.querySelector('[type="submit"]');
    const data=new FormData(form);
    const email=String(data.get('email')||'').trim();
    const password=String(data.get('password')||'');
    const remember=form.elements.remember.checked;
    button.disabled=true;
    say('Validando seu acesso…');
    try{
      if(activeUser&&activeUser.email?.toLowerCase()!==email.toLowerCase())await auth.signOut();
      activeUser=await auth.signIn(email,password,remember);
      localStorage.setItem('vuppi_remember',String(remember));
      say('Acesso confirmado. Abrindo seu painel…','success');
      await route(button);
    }catch(error){say(error.message||'Não foi possível entrar.','error');button.disabled=false}
  };
  continueButton.onclick=()=>route(continueButton);
  switchButton.onclick=async()=>{
    switchButton.disabled=true;
    try{await auth.signOut()}catch{}
    showSession(null);
    form.reset();
    form.elements.remember.checked=true;
    form.elements.email.focus();
    say('Sessão anterior encerrada. Entre com a outra conta.');
    switchButton.disabled=false;
  };
  (async()=>{
    try{const user=await auth.restore();if(user){showSession(user);say('Sua sessão continua ativa neste navegador.','success')}}
    catch{say('Não foi possível restaurar a sessão. Você pode entrar novamente.','error')}
  })();
})();
