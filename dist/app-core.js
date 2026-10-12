(function(global){
  'use strict';
  function versionParts(value){
    return String(value||'0').trim().replace(/^v/i,'').split('.').slice(0,4).map(part=>{
      const match=String(part).match(/^\d+/);return match?Number(match[0]):0;
    });
  }
  function compareVersions(left,right){
    const a=versionParts(left),b=versionParts(right),length=Math.max(a.length,b.length);
    for(let index=0;index<length;index++){const difference=(a[index]||0)-(b[index]||0);if(difference)return difference>0?1:-1}
    return 0;
  }
  function retryDelay(attempt,{base=1000,max=60000,jitter=.2,random=Math.random}={}){
    const raw=Math.min(max,base*(2**Math.max(0,Number(attempt)||0))),spread=raw*jitter;
    return Math.max(base,Math.round(raw-spread+(spread*2*random())));
  }
  class OfferController{
    constructor(){this.activeId='';this.processing=false}
    select(offers,rejected=new Set()){
      const visible=(Array.isArray(offers)?offers:[]).filter(offer=>offer?.id&&!rejected.has(offer.id));
      if(this.activeId&&visible.some(offer=>offer.id===this.activeId))return visible.find(offer=>offer.id===this.activeId);
      this.activeId=visible[0]?.id||'';return visible[0]||null;
    }
    begin(id){if(this.processing||!id||id!==this.activeId)return false;this.processing=true;return true}
    finish(id){if(!id||id===this.activeId)this.processing=false}
    dismiss(id){if(id===this.activeId)this.activeId='';this.processing=false}
  }
  global.VUPPICore={compareVersions,retryDelay,OfferController};
})(typeof window==='undefined'?globalThis:window);
