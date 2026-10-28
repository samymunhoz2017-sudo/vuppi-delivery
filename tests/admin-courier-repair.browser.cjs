// Run with Playwright available on NODE_PATH; all network responses are mocked.
const {chromium}=require('playwright');
const fs=require('fs');
const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe'});
 const page=await browser.newPage({viewport:{width:1280,height:800}});
 const id='11111111-1111-4111-8111-111111111111';
 await page.route('https://fixture.test/**',async route=>{
  const url=new URL(route.request().url());
  if(url.pathname==='/admin')return route.fulfill({contentType:'text/html',body:fs.readFileSync('dist/admin.html','utf8')});
  const path='dist/'+url.pathname.slice(1);
  if(fs.existsSync(path)&&fs.statSync(path).isFile())return route.fulfill({path});
  return route.fulfill({status:404,body:''});
 });
 await page.addInitScript(({id})=>{
  let member={user_id:id,kind:'courier',name:'Entregador Teste',email:'teste@example.test',phone:'',city:'',address:'Cadastro operacional ainda não concluído',registration_incomplete:true,approved:false,member_status:'pending'};
  window.__actions=[];
  const response=data=>new Response(JSON.stringify(data),{status:200,headers:{'Content-Type':'application/json'}});
  window.fetch=async(input,options={})=>{
   const url=new URL(String(input),location.href);
   if(url.pathname==='/api/auth/session')return response({user:{id:'admin',email:'admin@example.test'}});
   if(url.pathname==='/api/admin/status')return response({super_admin:true});
   if(url.pathname==='/api/admin/cities')return response([{id:'pitangueiras-sp',name:'Pitangueiras',uf:'SP',active:true}]);
   if(url.pathname==='/api/delivery/state')return response({admin:true,members:[member],orders:[],cities:[{id:'pitangueiras-sp',name:'Pitangueiras'}]});
   if(url.pathname==='/api/maps/config')return response({ready:false});
   if(url.pathname==='/api/delivery/address')return response({results:[{label:'Rua Pernambuco, Pitangueiras - SP'}]});
   if(url.pathname==='/api/delivery/action'){
    const body=JSON.parse(options.body);window.__actions.push(body);
    if(body.action==='admin_courier_register')member={...member,...body.data,user_id:id,registration_incomplete:false,approved:false,member_status:'pending'};
    if(body.action==='member_status')member={...member,approved:true,member_status:'active'};
    return response({ok:true});
   }
   return response({});
  };
 },{id});
 await page.goto('https://fixture.test/admin');
 await page.locator('[data-admin-tab="couriers"]').click();
 await page.locator('[data-courier-row]').first().click();
 await page.locator('[data-profile-tab="personal"]').click();
 await page.locator('#admin-courier-edit [name="phone"]').fill('16999999999');
 await page.locator('#admin-courier-edit [name="address"]').fill('Rua Pernambuco, 123');
 await page.locator('#admin-courier-edit [name="city"]').selectOption('pitangueiras-sp');
 await page.locator('#admin-courier-edit button[type="submit"], #admin-courier-edit button.primary').click();
 await page.waitForFunction(()=>window.__actions.some(a=>a.action==='admin_courier_register'));
 await page.locator('[data-profile-tab="permissions"]').click();
 await page.locator('[data-profile-status="active"]').click();
 await page.waitForFunction(()=>window.__actions.some(a=>a.action==='member_status'));
 const actions=await page.evaluate(()=>window.__actions);assert.equal(actions[0].action,'admin_courier_register');assert.equal(actions[0].data.address,'Rua Pernambuco, 123');assert.equal(actions[1].data.status,'active');
 console.log('Fluxo fictício: conta incompleta, edição, envio para análise e aprovação OK.');
 await browser.close();
})().catch(error=>{console.error(error);process.exit(1)});
