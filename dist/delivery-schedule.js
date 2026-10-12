addEventListener('DOMContentLoaded',()=>{
 const form=document.getElementById('order'),scheduled=form?.elements.namedItem('scheduled_for'),lead=form?.elements.namedItem('dispatch_lead_minutes');
 if(!form||!scheduled||!lead)return;
 const scheduledLabel=scheduled.closest('label'),leadLabel=lead.closest('label'),box=document.createElement('fieldset');
 box.className='dispatch-mode';box.innerHTML='<legend>Quando chamar o entregador</legend><div class="dispatch-options"><button type="button" data-dispatch="now" class="active">Agora</button><button type="button" data-dispatch="minutes">Em X minutos</button><button type="button" data-dispatch="schedule">Agendar</button></div><label class="dispatch-minutes" hidden>Chamar em quantos minutos<input name="dispatch_minutes" type="number" min="1" max="99" value="10"></label>';
 scheduledLabel.before(box);box.append(scheduledLabel,leadLabel);scheduledLabel.hidden=true;leadLabel.hidden=true;
 function select(mode){box.querySelectorAll('[data-dispatch]').forEach(b=>b.classList.toggle('active',b.dataset.dispatch===mode));box.querySelector('.dispatch-minutes').hidden=mode!=='minutes';scheduledLabel.hidden=mode!=='schedule';leadLabel.hidden=mode!=='schedule';form.dataset.dispatchMode=mode;if(mode!=='schedule')scheduled.value=''}
 box.querySelectorAll('[data-dispatch]').forEach(b=>b.onclick=()=>select(b.dataset.dispatch));select('now');
});
