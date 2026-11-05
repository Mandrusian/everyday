import {chromium} from 'playwright-core';
const FPS=30, args=process.argv.slice(2);
const times = args[0]==='test' ? [1.2,3.8,5.6,8.6,10.3,12.4,13.8,16.5,19,20.8] : null;
const b=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',args:['--use-angle=metal','--ignore-gpu-blocklist']});
const p=await b.newPage({viewport:{width:1280,height:720},deviceScaleFactor:1.5});
p.on('console',m=>{if(m.type()==='error')console.log('ERR',m.text())});p.on('pageerror',e=>console.log('PAGEERR',e.message));
await p.goto('http://localhost:8765/index.html');await p.waitForFunction('window.ready===true',null,{timeout:60000});
const total=await p.evaluate('TOTAL');
const list=times||Array.from({length:Math.ceil(total*FPS)},(_,i)=>i/FPS);
let i=0;for(const t of list){await p.evaluate(t=>seek(t),t);
  const name=times?`frames/t_${t}.jpg`:`frames/f_${String(i).padStart(4,'0')}.jpg`;
  await p.screenshot({path:name,type:'jpeg',quality:92});i++;}
console.log('frames',i,'total',total);await b.close();
