// Desenvolvimento local: exclusivo localhost, sem alterar HTTPS do Worker publicado.
import http from 'node:http';
import app from '../server/worker.mjs';
const port=8787,origin='http://localhost:'+port;
const env={};for(const name of ['SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY','UP_SESSION_KEY','UP_CITY_ID','SUPABASE_SECRET_KEY','GOOGLE_MAPS_SERVER_KEY'])env[name]=process.env[name];
if(!env.SUPABASE_URL||!env.SUPABASE_PUBLISHABLE_KEY||!env.UP_SESSION_KEY)throw Error('Use INICIAR-UP.cmd para configurar o cofre local.');
const server=http.createServer(async(incoming,outgoing)=>{
 try{
  // Evita exposição em rede e DNS rebinding. Apenas Host e Origin locais exatos.
  if(incoming.headers.host!=='localhost:'+port){outgoing.writeHead(403);outgoing.end('Endereço local não autorizado.');return}
  if(incoming.method==='POST'&&incoming.headers.origin!==origin){outgoing.writeHead(403);outgoing.end('Origem não autorizada.');return}
  const pathname=incoming.url||'/';if(!pathname.startsWith('/')||pathname.startsWith('//')){outgoing.writeHead(400);outgoing.end('Endereço inválido.');return}
  if(pathname.startsWith('/api/carros/realtime')){outgoing.writeHead(503);outgoing.end('Atualização periódica disponível no modo local.');return}
  const chunks=[];let size=0;for await(const chunk of incoming){size+=chunk.length;if(size>6*1024*1024){outgoing.writeHead(413);outgoing.end('Arquivo muito grande.');return}chunks.push(chunk)}
  const headers=new Headers();for(const [name,value] of Object.entries(incoming.headers))if(value)headers.set(name,Array.isArray(value)?value.join(','):value);
  // O adaptador autentica a origem HTTP local antes de usar origem virtual HTTPS.
  // Cookies Secure são aceitos em localhost pelos navegadores compatíveis.
  if(headers.has('Origin'))headers.set('Origin','https://localhost:'+port);
  const request=new Request('https://localhost:'+port+pathname,{method:incoming.method,headers,...(!['GET','HEAD'].includes(incoming.method)?{body:Buffer.concat(chunks)}:{})});
  const response=await app.fetch(request,env);outgoing.statusCode=response.status;
  for(const [name,value] of response.headers)if(name!=='set-cookie')outgoing.setHeader(name,value);
  const cookies=response.headers.getSetCookie();if(cookies.length)outgoing.setHeader('Set-Cookie',cookies);
  outgoing.end(Buffer.from(await response.arrayBuffer()));
 }catch{outgoing.writeHead(500,{'Content-Type':'text/plain; charset=utf-8'});outgoing.end('Não foi possível atender a solicitação local. Verifique o servidor e o Supabase.');}
});
server.listen(port,'127.0.0.1',()=>console.log('UP iniciada para desenvolvimento local. Abra '+origin+'\nAdministração: '+origin+'/admin\nMantenha esta janela aberta. Use Ctrl+C para encerrar.'));
server.on('error',()=>{console.error('Não foi possível iniciar a UP. A porta 8787 pode estar em uso.');process.exitCode=1});
