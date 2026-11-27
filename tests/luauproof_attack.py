#!/usr/bin/env python3
"""Finite adversarial GuardUtils differential tests. Reuse the pinned original
LuauProof 3.20 numeric grammar, input generator, rational oracle and VM.
This is not a formal proof or a Roblox Studio simulation."""
import argparse,ast,hashlib,json,random,subprocess,tempfile,time,sys
from pathlib import Path
from fractions import Fraction
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--luauproof',type=Path,required=True);p.add_argument('--source',type=Path,required=True);p.add_argument('--runner',type=Path,required=True);p.add_argument('--seed',type=int,default=20261127);p.add_argument('--programs',type=int,default=128);p.add_argument('--inputs',type=int,default=128);p.add_argument('--timing',type=int,default=2500);p.add_argument('--utf8',type=int,default=6000);p.add_argument('--out',type=Path,required=True);p.add_argument('--allow-differences',action='store_true');p.add_argument('--codegen',action='store_true');a=p.parse_args();t0=time.monotonic()
assert 16<=a.programs<=400 and 1<=a.inputs<=2048 and 1<=a.timing<=50000 and 1<=a.utf8<=100000
root=a.luauproof.resolve();sys.path.insert(0,str(root))
from vm_binary64_320 import pairs,COMPILER_LINUX
from numeric_fuzz320 import generate,expr,eval_ast
from binary64_320 import parts,encode,arithmetic,SIGN
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
pins={'numeric_fuzz320.py':'5d4cf91db579d2097cac2d13b9a77bef0bbad54878a47ad493a5d502d6f3e4b0','binary64_320.py':'8995a1949fcc910986bcfe38a9b9c406410db3c25929c45233f1a250a6fe8253','runtime/linux/luau':'7741b96bd8fadb340965b7468dc4a2be8fe41247b8219bd8d4a7e80f16b40625','runtime/linux/luau-compile':COMPILER_LINUX}
for path,pin in pins.items():assert sha(root/path)==pin,(path,'tool identity changed')
def finite(b):
 s,k,x=parts(b);return (-x if s else x) if k in ('finite','zero') else None
def bits(x):return encode(abs(x),x<0)
def lh(b):return f'{b&0xffffffff},{b>>32}'
def bl(x):return 'true' if x else 'false'
def ls(v):return '"'+''.join('\\%03d'%x for x in v)+'"'
SAFE=Fraction(2**50);bounds=[(0,10),(-SAFE,SAFE),(Fraction(-3,2),Fraction(3,2)),(Fraction(1,4),Fraction(3,4)),(-1,0),(0,0)]
bounds=[(Fraction(x),Fraction(y)) for x,y in bounds]
def san(x,lo,hi,integer,clamp):
 if x is None:return None
 if not clamp and not lo<=x<=hi:return None
 if integer:lo=Fraction(-((-lo.numerator)//lo.denominator));hi=Fraction(hi.numerator//hi.denominator);x=Fraction(x.numerator//x.denominator)
 if lo>hi:return None
 if not lo<=x<=hi:
  if not clamp:return None
  x=min(hi,max(lo,x))
 return bits(x)
rng=random.Random(a.seed);pool=pairs(a.seed,max(a.inputs*4,a.timing*2));ps=rng.sample(pool,a.inputs);trees=generate(a.seed,a.programs);assert len(trees)==a.programs
mod=ast.parse(a.runner.read_text());prefix=next(ast.literal_eval(n.value) for n in mod.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='prefix' for t in n.targets))
body=[r'''
local counts, failures = {}, {}
local function check(group,truth,id,expected,observed)
 counts[group]=(counts[group] or 0)+1
 if not truth then failures[group]=(failures[group] or 0)+1; if failures[group]<=8 then print("DIFF",group,id,tostring(expected),tostring(observed)) end end
end
local function frombits(lo,hi) return string.unpack("<d",string.pack("<I4I4",lo,hi)) end
local function matchbits(x,lo,hi)
 if type(x)~="number" then return false end
 local e=frombits(lo,hi); if e~=e then return x~=x end
 if e==0 then return x==0 end
 return string.pack("<d",x)==string.pack("<d",e)
end
local function checkSan(id,v,lo,hi,integer,clamp,expected,elo,ehi)
 local got,code=Guard.sanitizeNumber(v,lo,hi,{Integer=integer,Clamp=clamp})
 local ok=if expected then matchbits(got,elo,ehi) else got==nil and type(code)=="string"
 check("sanitize_number",ok,id,if expected then frombits(elo,ehi) else "reject",got or code)
end
local funcs={}
''']
for j,t in enumerate(trees):body.append(f'funcs[{j+1}]=function(a,b) return {expr(t)} end')
body.append(r'''
local bounds={{0,10},{-2^50,2^50},{-1.5,1.5},{0.25,0.75},{-1,0},{0,0}}
local function numberCase(id,fn,alo,ahi,blo,bhi,vlo,vhi,valid,mode,expect,elo,ehi)
 local v=funcs[fn](frombits(alo,ahi),frombits(blo,bhi))
 check("numeric_oracle",matchbits(v,vlo,vhi),id,frombits(vlo,vhi),v)
 local good=Guard.validateData(v);check("validate_number",good==valid,id,valid,good)
 local b=bounds[math.floor(mode/4)+1];checkSan(id,v,b[1],b[2],mode%2==1,math.floor(mode/2)%2==1,expect,elo,ehi)
end
''')
num=0
for j,t in enumerate(trees):
 for i,(x,y) in enumerate(ps):
  b=eval_ast(t,x,y);v=finite(b);valid=v is not None and abs(v)<=SAFE;mode=(j*7+i*13)%24;lo,hi=bounds[mode//4];e=san(v,lo,hi,bool(mode%2),bool(mode//2%2));body.append(f'numberCase({num},{j+1},{lh(x)},{lh(y)},{lh(b)},{bl(valid)},{mode},{bl(e is not None)},{lh(e or 0)})');num+=1
body.append(r'''
local function directCase(id,alo,ahi,blo,bhi,vlo,vhi,mode,expect,elo,ehi)
 checkSan(id,frombits(vlo,vhi),frombits(alo,ahi),frombits(blo,bhi),mode%2==1,math.floor(mode/2)%2==1,expect,elo,ehi)
end
''')
direct=0
for i,(x,y) in enumerate(pool[:16000]):
 b=pool[(i*13+7)%len(pool)][i%2];v=finite(b);lo,hi=finite(x),finite(y);mode=i%4
 if i%3==0 and lo is not None and hi is not None and lo>hi:x,y,lo,hi=y,x,hi,lo
 good=lo is not None and hi is not None and -SAFE<=lo<=hi<=SAFE;e=san(v,lo,hi,bool(mode%2),bool(mode//2%2)) if good else None;body.append(f'directCase({i},{lh(x)},{lh(y)},{lh(b)},{mode},{bl(e is not None)},{lh(e or 0)})');direct+=1
body.append(r'''
local function timeCase(id,slo,shi,dlo,dhi,nlo,nhi,expired)
 Guard.Stop();resetScheduler();clock=frombits(slo,shi);local d=frombits(dlo,dhi);local ns={}
 local token,e=Guard.acquireMutex(ns,"key",d);local owned=token and Guard.ownsMutex(ns,"key",token)
 check("lease_initial",owned==true,id,true,owned or e)
 check("rate_initial",Guard.isRateLimited("key",1,d)==false,id,false,"initial admission")
 clock=frombits(nlo,nhi);local owns=Guard.ownsMutex(ns,"key",token)
 check("lease_expiry",owns==(not expired),id,not expired,owns)
 local limited=Guard.isRateLimited("key",1,d);check("rate_expiry",limited==(not expired),id,not expired,limited)
 local renewed=Guard.renewMutex(ns,"key",token,d);check("lease_renew",renewed==(not expired),id,not expired,renewed)
 local v=renewed and Guard.ownsMutex(ns,"key",token) or false
 check("lease_renew_initial",v==(not expired),id,not expired,v)
end
''')
starts=[bits(Fraction(v)) for v in (0,1,10,1000,100000,2**20,2**32,2**50)]+[1,2,3,0x0010000000000000]
durs=[1,2,3,0x0010000000000000]+[bits(Fraction(v)) for v in (Fraction(1,2**52),Fraction(1,2**40),Fraction(1,1000),1,3600)]
for x,y in pool:
 for b in (x&~SIGN,y&~SIGN):
  v=finite(b)
  if v is not None:
   if v<=2**50:starts.append(b)
   if 0<v<=3600:durs.append(b)
starts=list(dict.fromkeys(starts));durs=list(dict.fromkeys(durs));triples=[(1,bits(Fraction(1)),bits(Fraction(1))),(bits(Fraction(1000)),1,bits(Fraction(1000)))]
for i in range(a.timing):
 st=rng.choice(starts if i%3 else starts[:12]);d=rng.choice(durs if i%3 else durs[:9]);end=arithmetic('add',st,d)
 for n in (st,max(st,end-1),end,end+1):
  if finite(n) is not None and finite(n)>=finite(st):triples.append((st,d,n))
triples=list(dict.fromkeys(triples))
for i,(st,d,n) in enumerate(triples):body.append(f'timeCase({i},{lh(st)},{lh(d)},{lh(n)},{bl(finite(n)-finite(st)>=finite(d))})')
body.append(r'''
local function stringCase(id,s,limit,valid,expect,cleaned)
 local v=Guard.validateData(s);check("validate_utf8",v==valid,id,valid,v)
 local got,code=Guard.sanitizeString(s,limit);local ok=if expect then got==cleaned else got==nil and type(code)=="string"
 check("sanitize_utf8",ok,id,if expect then "accept" else "reject",if got then "accept" else code)
end
''')
utf=[b'',b'\xc2\x00\xa2',b'\xe2\x00\x82\xac',b'\xf0\x9f\x7f\x92\xa9',b'\xed\xa0\x80',b'\xc0\x80',b'\xf4\x90\x80\x80']
for i in range(a.utf8):
 m=i%5
 if m==0:v=bytes(rng.randrange(256) for _ in range(rng.randrange(24)))
 elif m in (1,2,3):
  cps=[rng.randrange(0x110000) for _ in range(rng.randrange(1,16))];v=''.join(chr(0xfffd if 0xd800<=c<=0xdfff else c) for c in cps).encode()
  if m==2:j=rng.randrange(len(v)+1);v=v[:j]+bytes([rng.choice([0,1,9,10,31,127])])+v[j:]
  elif m==3:j=rng.randrange(len(v));v=v[:j]+bytes([rng.randrange(256)])+v[j+1:]
 else:v=bytes(rng.randrange(128) for _ in range(rng.randrange(40)))
 utf.append(v)
for i,v in enumerate(utf):
 limit=i%20+1
 try:v.decode('utf-8');valid=b'\0' not in v;clean=bytes(x for x in v if x>=32 and x!=127).strip(b' ');e=bool(clean) and len(clean.decode('utf-8'))<=limit
 except UnicodeDecodeError:valid=False;clean=b'';e=False
 body.append(f'stringCase({i},{ls(v)},{limit},{bl(valid)},{bl(e)},{ls(clean)})')
body.append('for group,n in pairs(counts) do print("RESULT",group,n,failures[group] or 0) end')
# Small function batches avoid constant/instruction limits.
output=[];batch=[]
def flush():
 if batch:output.append('do\nlocal function batch()\n'+'\n'.join(batch)+'\nend\nbatch()\nend');batch.clear()
for line in '\n'.join(body).splitlines():
 if line.startswith(('numberCase(','directCase(','timeCase(','stringCase(')):
  batch.append(line)
  if len(batch)>=256:flush()
 else:flush();output.append(line)
flush();src=prefix+a.source.read_text()+'\nend)()\n'+'\n'.join(output)+'\n'
expected_counts={'numeric_oracle':num,'validate_number':num,'sanitize_number':num+direct,'lease_initial':len(triples),'rate_initial':len(triples),'lease_expiry':len(triples),'rate_expiry':len(triples),'lease_renew':len(triples),'lease_renew_initial':len(triples),'validate_utf8':len(utf),'sanitize_utf8':len(utf)}
report={'schema':2,'expected_counts_per_run':expected_counts,'scope':'Finite GuardUtils differential attack with original LuauProof 3.20 grammar, input generator, rational binary64 oracle, bundled VM and Roblox service doubles; not a formal proof or Studio test.','source_sha256':sha(a.source),'runner_sha256':sha(a.runner),'campaign_sha256':sha(Path(__file__)),'tool_pins':pins,'seed':a.seed,'programs':len(trees),'inputs':len(ps),'numeric_expression_cases':num,'direct_sanitize_cases':direct,'timing_cases':len(triples),'utf8_cases':len(utf),'generated_harness_sha256':hashlib.sha256(src.encode()).hexdigest(),'runs':[]}
with tempfile.TemporaryDirectory() as td:
 f=Path(td)/'attack.luau';f.write_text(src)
 for opt,cg in [(0,False),(1,False),(2,False)]+([(2,True)] if a.codegen else []):
  st=time.monotonic();cmd=[str(root/'runtime/linux/luau'),f'-O{opt}']+(['--codegen'] if cg else [])+[str(f)]
  try:
   proc=subprocess.run(cmd,capture_output=True,text=True,timeout=90);results={};examples=[]
   for line in proc.stdout.splitlines():
    z=line.split('\t')
    if z[0]=='RESULT':
     assert z[1] not in results, ('duplicate result', z[1]);results[z[1]]={'checks':int(z[2]),'differences':int(z[3])}
    elif z[0]=='DIFF':examples.append(z[1:])
   run={'optimization':opt,'codegen':cg,'seconds':time.monotonic()-st,'returncode':proc.returncode,'results':results,'examples':examples,'stderr':proc.stderr[:2000]}
  except subprocess.TimeoutExpired:run={'optimization':opt,'codegen':cg,'seconds':time.monotonic()-st,'timeout':True,'results':{},'examples':[]}
  report['runs'].append(run);print('RUN',opt,cg,round(run['seconds'],3),run.get('returncode'),{k:(v['checks'],v['differences']) for k,v in run['results'].items()},flush=True)
  if run.get('stderr'):print(run['stderr'],flush=True)
report['elapsed_seconds']=time.monotonic()-t0;report['checks']=sum(v['checks'] for r in report['runs'] for v in r['results'].values());report['differences']=sum(v['differences'] for r in report['runs'] for v in r['results'].values());report['status']='INCOMPLETE' if any(r.get('returncode')!=0 or r.get('stderr') or {k:v['checks'] for k,v in r['results'].items()}!=expected_counts or any(not 0<=v['differences']<=v['checks'] for v in r['results'].values()) for r in report['runs']) else 'DIFFERENCE_OBSERVED' if report['differences'] else 'FINITE_TESTS_AGREE'
a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(report,indent=2)+'\n');print(report['status'],report['checks'],report['differences'],report['elapsed_seconds'],flush=True);raise SystemExit(0 if report['status']=='FINITE_TESTS_AGREE' or a.allow_differences and report['status']=='DIFFERENCE_OBSERVED' else 2)
