(function(){
 'use strict';
 async function cep(input,target){const value=input.value.replace(/\D/g,'');if(value.length!==8)return;const r=await fetch('/api/delivery/cep?cep='+value,{credentials:'same-origin'}),d=await r.json();if(!r.ok)throw Error(d.message||'CEP não encontrado.');target.value=d.address+', ';target.focus()}
 function enhance(){const form=document.getElementById('new-merchant');if(form&&!form.dataset.enhanced){form.dataset.enhanced='1';const address=form.elements.address,cepField=form.elements.cep;if(cepField&&address)cepField.addEventListener('input',e=>{if(e.target.value.replace(/\D/g,'').length===8)cep(e.target,address).catch(x=>window.dispatchEvent(new CustomEvent('vuppi:admin-error',{detail:x.message})))});}}
 new MutationObserver(enhance).observe(document.documentElement,{childList:true,subtree:true});addEventListener('DOMContentLoaded',enhance);
})();
