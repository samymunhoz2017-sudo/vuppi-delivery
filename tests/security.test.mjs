import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createWorker} from '../server/worker.mjs';
import assets from '../server/assets.mjs';
const env={SUPABASE_URL:'https://fixture.supabase.co',SUPABASE_PUBLISHABLE_KEY:'sb_publishable_test_only',UP_SESSION_KEY:Buffer.alloc(32,7).toString('base64'),UP_CITY_ID:'pitangueiras-sp'};
const origin='https://central.example';let confirm=false,remoteDown=false,signupCalls=0,refreshCalls=0,expired=false,accessRows=[];
const token={access_token:'FIXTURE_ACCESS_TOKEN',refresh_token:'FIXTURE_REFRESH_TOKEN',expires_in:3600};
const calls=[];
const upstream=async(url,options)=>{calls.push({url,options});if(remoteDown)throw Error('Sem conexÃ£o');const ok=data=>Response.json(data);
 if(url.endsWith('/settings'))return ok({mailer_autoconfirm:confirm});
 if(url.includes('grant_type=password')){if(JSON.parse(options.body).password==='errada')return Response.json({error_code:'invalid_credentials'},{status:400});return ok({...token,expires_in:expired?1:3600})}
 if(url.endsWith('/signup')){signupCalls++;return ok(token)}
 if(url.includes('grant_type=refresh_token')){refreshCalls++;return ok({...token,access_token:'FIXTURE_RENEWED_TOKEN'})}
 if(url.endsWith('/user'))return ok({id:'fixture-user',email:'teste@exemplo.com',user_metadata:{role:'master'},app_metadata:{private:'INFORMACAO_INTERNA'}});
 if(url.includes('/rest/v1/'))return ok(accessRows);
 if(url.includes('/logout'))return new Response(null,{status:204});
 throw Error('Endpoint inesperado');
};
const app=createWorker(assets,upstream);
const req=(path,{method='GET',body,cookie,originHeader=origin,headers={}}={})=>new Request(origin+path,{method,headers:{...(method==='POST'?{Origin:originHeader,'Content-Type':'application/json'}:{}),...(cookie?{Cookie:cookie}:{}),...headers},...(body?{body:typeof body==='string'?body:JSON.stringify(body)}:{})});
const send=(path,options)=>app.fetch(req(path,options),env);
let response=await send('/api/auth/status');assert.deepEqual(await response.json(),{ready:true});
response=await send('/api/app/version?platform=android');assert.equal(response.status,200);const appVersion=await response.json();assert.equal(appVersion.latest_version,'0.80.0');assert.equal(appVersion.minimum_supported_version,'0.55.0');assert.equal(appVersion.active,true);assert.equal(appVersion.store_url,'/downloads/vuppi-entregador.apk');
response=await app.fetch(req('/api/app/version?platform=android'),{...env,UP_ANDROID_LATEST_VERSION:'0.64.0'});assert.equal((await response.json()).latest_version,'0.80.0');
response=await send('/downloads/vuppi-entregador.apk');assert.match(response.headers.get('Content-Disposition'),/Vuppi-Entregador-0\.80\.0\.apk/);
response=await app.fetch(req('/api/auth/status'),{});assert.deepEqual(await response.json(),{ready:false});
response=await send('/api/auth/session');assert.equal(response.status,401);
response=await send('/api/auth/login',{method:'POST',body:{email:'teste@exemplo.com',password:'teste'},originHeader:'https://outro.example'});assert.equal(response.status,403);assert.equal(calls.length,0);
response=await send('/api/auth/login',{method:'POST',body:{email:'teste@exemplo.com',password:'errada'}});assert.equal(response.status,400);assert.match((await response.json()).message,/incorretos/);
response=await send('/api/auth/signup',{method:'POST',body:{name:'Teste',email:'teste@exemplo.com',password:'senha-ficticia'}});assert.equal(response.status,400);assert.equal(signupCalls,0);
confirm=true;response=await send('/api/auth/signup',{method:'POST',body:{name:'Teste',email:'teste@exemplo.com',password:'senha-ficticia',role:'master'}});assert.equal(response.status,200);assert.equal(signupCalls,1);const signup=JSON.parse(calls.find(c=>c.url.endsWith('/signup')).options.body);assert.equal(signup.data.role,undefined);
const publicBody=await response.text(),setCookie=response.headers.get('Set-Cookie');assert.ok(!publicBody.includes('FIXTURE_'));assert.ok(!publicBody.includes('INFORMACAO_INTERNA'));assert.match(setCookie,/HttpOnly/);assert.match(setCookie,/Secure/);assert.match(setCookie,/SameSite=Lax/);assert.ok(!setCookie.includes(token.access_token));assert.ok(!setCookie.includes(token.refresh_token));const sessionCookie=setCookie.split(';')[0];
response=await send('/api/auth/login',{method:'POST',body:{email:'teste@exemplo.com',password:'teste',remember:true}});assert.match(response.headers.get('Set-Cookie'),/Max-Age=2592000/);assert.match(response.headers.get('Set-Cookie'),/Expires=/);
response=await app.fetch(new Request(origin+'/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json','X-Vuppi-Client':'courier-native'},body:JSON.stringify({email:'teste@exemplo.com',password:'teste',remember:true})}),env);assert.equal(response.status,200);assert.equal(response.headers.get('Set-Cookie'),null);const nativeLogin=await response.json();assert.equal(nativeLogin.user.email,'teste@exemplo.com');assert.match(nativeLogin.session,/^[\w-]+\.[\w-]+$/);assert.ok(!nativeLogin.session.includes(token.access_token));
response=await app.fetch(new Request(origin+'/api/auth/session',{headers:{'X-Vuppi-Client':'courier-native',Authorization:'Vuppi '+nativeLogin.session}}),env);assert.equal(response.status,200);assert.equal((await response.json()).user.email,'teste@exemplo.com');
response=await send('/api/auth/session',{cookie:sessionCookie});assert.equal(response.status,200);assert.equal((await response.json()).hasAccess,false);
accessRows=[{usuario_id:'outro',cidade_id:'pitangueiras-sp',papel:'master',ativo:true},{usuario_id:'fixture-user',cidade_id:'outra-cidade',papel:'master',ativo:true},{usuario_id:'fixture-user',cidade_id:'pitangueiras-sp',papel:'gestor',ativo:false}];response=await send('/api/auth/access',{cookie:sessionCookie});assert.deepEqual((await response.json()).access,[]);
accessRows.push({usuario_id:'fixture-user',cidade_id:'pitangueiras-sp',papel:'gestor',ativo:true});response=await send('/api/auth/access',{cookie:sessionCookie});assert.equal((await response.json()).access.length,1);
const parts=sessionCookie.split('.');parts[1]=(parts[1][0]==='A'?'B':'A')+parts[1].slice(1);response=await send('/api/auth/session',{cookie:parts.join('.')});assert.equal(response.status,401);
response=await app.fetch(new Request('https://outro.example/api/auth/session',{headers:{Cookie:sessionCookie}}),env);assert.equal(response.status,401);
response=await send('/api/auth/login',{method:'POST',body:'{"data":"'+'a'.repeat(9000)+'"}'});assert.equal(response.status,413);
response=await send('/api/auth/login',{method:'POST',body:'{}',headers:{'Content-Type':'text/plain'}});assert.equal(response.status,415);
response=await app.fetch(new Request('http://central.example/api/auth/session'),env);assert.equal(response.status,400);
expired=true;response=await send('/api/auth/login',{method:'POST',body:{email:'teste@exemplo.com',password:'teste'}});const shortCookie=response.headers.get('Set-Cookie').split(';')[0];await Promise.all([send('/api/auth/session',{cookie:shortCookie}),send('/api/auth/session',{cookie:shortCookie})]);assert.equal(refreshCalls,1);
remoteDown=true;response=await send('/api/auth/logout',{method:'POST',cookie:sessionCookie,body:{}});assert.equal(response.status,200);assert.match(response.headers.get('Set-Cookie'),/Max-Age=0/);assert.equal((await response.json()).remote,false);remoteDown=false;
for(const path of Object.keys(assets)){response=await send(path);const content=await response.text();assert.ok(!content.includes(env.SUPABASE_PUBLISHABLE_KEY));assert.ok(!content.includes(env.UP_SESSION_KEY));assert.ok(!content.includes(token.access_token));assert.match(response.headers.get('Content-Security-Policy'),/connect-src 'self'/);}
response=await send('/.env');assert.equal(response.status,404);response=await send('/server/worker.mjs');assert.equal(response.status,404);
const client=readFileSync(new URL('../dist/auth-client.js',import.meta.url),'utf8');assert.ok(!/sessionStorage|localStorage|refresh_token|access_token|apikey/.test(client));
console.log('Aprovado: chave fora dos arquivos pÃºblicos; cookie criptografado; HTTPS; CSRF; cookie adulterado; separaÃ§Ã£o por origem; limites de corpo; permissÃµes por usuÃ¡rio/cidade; cadastro sem confirmaÃ§Ã£o; renovaÃ§Ã£o; saÃ­da; CSP e bloqueio de arquivos privados.');
