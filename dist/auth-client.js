/* O navegador usa apenas a API da UP. Não recebe chaves nem tokens Supabase. */
(function(global){
  'use strict';
  class AuthError extends Error{constructor(message,status=0){super(message);this.status=status}}
  function create(config,{fetcher=global.fetch.bind(global)}={}){
    const base=config.authApi||'/api/auth';
    if(base!=='/api/auth')throw new AuthError('A autenticação deve usar o servidor da VUPPI MOB.');
    async function request(path,body){const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),20000);try{const response=await fetcher(base+path,{method:body?'POST':'GET',credentials:'same-origin',headers:body?{'Content-Type':'application/json'}:{},...(body?{body:JSON.stringify(body)}:{}),signal:controller.signal});let data;try{data=await response.json()}catch{throw new AuthError('O servidor da VUPPI MOB não está disponível neste endereço.')}if(!response.ok)throw new AuthError(data?.message||'Não foi possível concluir a solicitação.',response.status);return data} catch(e){if(e instanceof AuthError)throw e;throw new AuthError('Não foi possível conectar à central. Verifique sua internet.')}finally{clearTimeout(timer)}}
    return {
      async status(){return request('/status')},
      async signIn(email,password,remember=false){return (await request('/login',{email,password,remember:remember===true})).user},
      async signUp(name,email,password){return (await request('/signup',{name,email,password})).user},
      async getUser(){return (await request('/session')).user},
      async getAccess(){return (await request('/access')).access},
      async restore(){try{return await this.getUser()}catch(e){if(e.status===401)return null;throw e}},
      async signOut(){return request('/logout',{})},
      projectUrl:location.origin
    };
  }
  global.UPAuthClient={create,AuthError};
})(window);
