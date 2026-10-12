// Adaptador Node.js para hospedagem com HTTPS terminado pelo proxy do provedor.
// Origem fixa: nunca deriva a origem da sessão de cabeçalhos fornecidos pelo cliente.
export function publicOrigin(value){const url=new URL(value);if(url.protocol!=='https:'||url.username||url.password||url.port||url.pathname!=='/'||url.search||url.hash)throw Error('Configure uma origem HTTPS válida, sem caminhos.');return url.origin}
export async function gatewayRequest(incoming,origin){
 const path=incoming.url||'/';if(!path.startsWith('/')||path.startsWith('//'))throw Object.assign(Error('Endereço inválido.'),{status:400});
 const url=new URL(origin+path);if(url.origin!==origin)throw Object.assign(Error('Origem inválida.'),{status:400});
 const headers=new Headers();for(const [key,value] of Object.entries(incoming.headers))if(value)headers.set(key,Array.isArray(value)?value.join(','):String(value));
 const chunks=[];let size=0;for await(const chunk of incoming){size+=chunk.length;if(size>6*1024*1024)throw Object.assign(Error('Solicitação muito grande.'),{status:413});chunks.push(chunk)}
 return new Request(url,{method:incoming.method,headers,...(!['GET','HEAD'].includes(incoming.method)?{body:Buffer.concat(chunks)}:{})});
}
export async function gatewayResponse(response,outgoing){
 outgoing.statusCode=response.status;for(const [key,value] of response.headers)if(key!=='set-cookie')outgoing.setHeader(key,value);
 const cookies=response.headers.getSetCookie();if(cookies.length)outgoing.setHeader('Set-Cookie',cookies);
 outgoing.end(Buffer.from(await response.arrayBuffer()));
}
