/** Local-only overlay scenarios. Proxy the original Android dev gateway on 8799. */
let scenario='ready';
let answers=0;
const requests: string[]=[];
const server=Bun.serve({hostname:'127.0.0.1',port:8800,async fetch(request){
  const url=new URL(request.url);
  if(url.pathname==='/api/review/scenario') {scenario=url.searchParams.get('kind')??'ready';return Response.json({scenario,answers});}
  if(url.pathname==='/api/review/evidence') return Response.json({scenario,answers,requests});
  if(url.pathname.includes('/snapshot') && scenario==='offline') return Response.json({error:{code:'unavailable',message:'Review server unavailable'}},{status:503});
  if(url.pathname.includes('/interactions/') && url.pathname.endsWith('/answer')) {answers++;scenario='handled';requests.push('answer');return Response.json({interactionId:'review-q',status:'answered'});}
  if(url.pathname==='/api/schedules/review') return Response.json({schedule:{id:'review',title:'每天早上檢查測試'},runs:[{id:'review-run',status:scenario==='handled'?'dismissed':'missed',dueAt:Date.now()-3600000}]});
  if(url.pathname.startsWith('/api/schedules/review/') && request.method==='POST') {requests.push(url.pathname);scenario='handled';return Response.json({status:'accepted'});}
  if(url.pathname.includes('/control') && scenario==='controlled') return Response.json({lease:{clientId:'desktop',generation:99,expiresAt:Date.now()+60000,expired:false},heldByCurrentClient:false});
  const proxy=new URL(request.url);proxy.hostname='127.0.0.1';proxy.port='8799';
  const response=await fetch(proxy,{method:request.method,headers:request.headers,body:request.method==='GET'||request.method==='HEAD'?undefined:await request.arrayBuffer()});
  if(url.pathname.endsWith('/snapshot') && response.ok) {
    const data:any=await response.json();data.interactions=[{id:'review-q',rpcId:'review-rpc',sessionId:'s1',runnerEpoch:2,kind:'select',status:scenario==='handled'?'answered':'pending',request:{title:'是否只重新執行失敗案例？',message:'只重跑約 4 分鐘；全部重跑約 38 分鐘。',options:['只重跑失敗的 3 個案例','全部重跑','先提供報告']},expiresAt:scenario==='expired'?Date.now()-1000:Date.now()+600000}];
    return Response.json(data);
  }
  return response;
}});
console.log(`Review gateway on ${server.url}`);
