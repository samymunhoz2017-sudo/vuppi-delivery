addEventListener('DOMContentLoaded',()=>{
 const form=document.getElementById('order'),mode=form?.elements.namedItem('dispatch_mode'),minutes=document.getElementById('dispatchMinutesField'),schedule=document.getElementById('dispatchScheduleField'),scheduled=form?.elements.namedItem('scheduled_for');
 if(!form||!mode||!minutes||!schedule||!scheduled)return;
 const sync=()=>{minutes.hidden=mode.value!=='minutes';schedule.hidden=mode.value!=='schedule';form.elements.dispatch_minutes.required=mode.value==='minutes';scheduled.required=mode.value==='schedule';if(mode.value!=='schedule')scheduled.value=''};
 mode.addEventListener('change',sync);form.addEventListener('reset',()=>setTimeout(sync));sync();
});
