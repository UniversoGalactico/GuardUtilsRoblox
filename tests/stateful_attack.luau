-- Adversarial cross-API model: integer ticks are exact dyadic timestamps.
-- The model uses simple queues and tables, not GuardUtils implementation helpers.
local operations,checks=0,0
local function eq(actual,expected,context)
 checks+=1
 if actual~=expected then error(context..": expected "..tostring(expected)..", got "..tostring(actual),2) end
end
local function testSeed(seed,steps)
 Guard.Stop();resetScheduler();clock=0
 local tick=0;local modelClock=0;local state=false
 local namespaces={};for i=1,6 do namespaces[i]={} end
 local rate,regs,oldTokens={},{},{}
 local function rnd(n) seed=(seed*16807)%2147483647;return seed%n+1 end
 local function observe() modelClock=math.max(modelClock,tick) end
 local function cleanRate(k)
  local r=rate[k];if not r then return end
  local q={};for _,t in ipairs(r.times) do if modelClock-t<r.window then table.insert(q,t) end end;r.times=q
 end
 local function maintenance()
  observe()
  for k,r in pairs(rate) do cleanRate(k);if #r.times==0 and modelClock-r.last>=120*16 then rate[k]=nil end end
  for _,r in pairs(regs) do for k,l in pairs(r.locks) do if modelClock>=l.deadline then r.locks[k]=nil end end end
 end
 local function checkStats()
  observe();local keys,times,nregs,records,active=0,0,0,0,0
  for _,r in pairs(rate) do keys+=1;times+=#r.times end
  for _,r in pairs(regs) do nregs+=1;for _,l in pairs(r.locks) do records+=1;if modelClock<l.deadline then active+=1 end end end
  local s=Guard.GetStats();eq(s.RateLimitKeys,keys,"rate keys");eq(s.RateLimitTimestamps,times,"rate timestamps");eq(s.MutexRegistrations,nregs,"registrations");eq(s.MutexRecords,records,"mutex records");eq(s.ActiveMutexes,active,"active mutexes");eq(s.Running,state,"watchdog state")
 end
 for i=1,steps do
  operations+=1
  local op=rnd(20);local n=rnd(6);local k=rnd(9);local ns=namespaces[n];local rk="p"..rnd(3)..":"..rnd(11);local duration=rnd(8)*4;local r=regs[n];local lock=r and r.locks[k];local key=n..":"..k
  local ctx="seed-step "..i.." op "..op
  if op==1 then tick+=rnd(65)-1;clock=tick/16
  elseif op==2 then tick=math.max(0,tick-rnd(17));clock=tick/16
  elseif op<=6 then
   state=true;observe();local lim=rnd(4);local win=rnd(4)*8;local e=rate[rk];local expected,code
   if e and (e.limit~=lim or e.window~=win) then expected=true;code="RATE_LIMIT_POLICY_MISMATCH"
   else
    if not e then e={limit=lim,window=win,last=modelClock,times={}};rate[rk]=e end
    cleanRate(rk);e.last=modelClock;expected=#e.times>=lim
    if not expected then table.insert(e.times,modelClock) end
   end
   local got,err=Guard.isRateLimited(rk,lim,win/16);eq(got,expected,ctx);eq(err,code,ctx.." code")
  elseif op==7 then rate[rk]=nil;eq(Guard.cleanupRateLimit(rk),true,ctx)
  elseif op==8 then local prefix="p"..rnd(3)..":";for x in pairs(rate) do if x:sub(1,#prefix)==prefix then rate[x]=nil end end;eq(Guard.cleanupRateLimitPrefix(prefix),true,ctx)
  elseif op==9 then
   state=true;local id,err=Guard.registerMutexTable(ns,duration/16);eq(type(id),"string",ctx);eq(err,nil,ctx)
   if r then if r.id then eq(id,r.id,ctx) end;r.id=id;r.duration=duration else regs[n]={id=id,duration=duration,locks={}} end
  elseif op==10 or op==11 then
   state=true;observe();local explicit=if rnd(2)==1 then duration else nil
   local token,err=Guard.acquireMutex(ns,k,if explicit then explicit/16 else nil)
   if not r then r={id=nil,duration=480,locks={}};regs[n]=r end
   if lock and modelClock<lock.deadline then eq(token,nil,ctx);eq(err,"LOCKED",ctx)
   else eq(type(token),"string",ctx);eq(err,nil,ctx);if oldTokens[key] then eq(token==oldTokens[key],false,ctx.." stale") end;oldTokens[key]=token;r.locks[k]={token=token,deadline=modelClock+(explicit or r.duration)};eq(Guard.ownsMutex(ns,k,token),true,ctx) end
  elseif op==12 or op==13 then
   local token=if rnd(3)==1 then "forged" else oldTokens[key] or "missing"
   -- readClock only advances for current matching owners.
   local success,code=false,nil
   if not lock then code="NOT_LOCKED" elseif lock.token~=token then code="NOT_OWNER"
   else observe();if modelClock>=lock.deadline then code="LOCK_EXPIRED";r.locks[k]=nil elseif op==12 then success=true;r.locks[k]=nil else success=true;lock.deadline=modelClock+duration end end
   local got,err;if op==12 then got,err=Guard.releaseMutex(ns,k,token) else got,err=Guard.renewMutex(ns,k,token,duration/16) end
   eq(got,success,ctx);eq(err,code,ctx.." code")
  elseif op==14 then
   if lock then observe() end
   eq(Guard.isMutexLocked(ns,k),lock~=nil and modelClock<lock.deadline,ctx)
  elseif op==15 then
   local active=false
   if r then observe();for x,l in pairs(r.locks) do if modelClock>=l.deadline then r.locks[x]=nil else active=true end end end
   local success,code=Guard.unregisterMutexTable(ns)
   eq(success,r~=nil and not active,ctx);eq(code,if not r then "NOT_REGISTERED" elseif active then "ACTIVE_LEASES" else nil,ctx.." code")
   if success then regs[n]=nil end
  elseif op==16 then maintenance();eq(Guard.runMaintenance(),true,ctx)
  elseif op==17 then state=false;eq(Guard.Stop(false),true,ctx)
  elseif op==18 then state=false;rate={};regs={};modelClock=0;eq(Guard.Stop(),true,ctx)
  elseif op==19 then state=true;eq(Guard.Start(),true,ctx)
  else
   -- Invalid inputs must neither create state nor start a stopped watchdog.
   local s=Guard.GetStats();observe();eq(Guard.isRateLimited({},1,1),true,ctx);eq(Guard.acquireMutex(ns,0/0),nil,ctx);eq(Guard.registerMutexTable(ns,math.huge),nil,ctx);eq(Guard.Stop("invalid"),false,ctx);eq(Guard.GetStats().Running,s.Running,ctx)
  end
  if i%11==0 then checkStats() end
 end
 checkStats()
end
for _,seed in ipairs({1111,7919,3182026,20261127,17041,2147483000,9967,719}) do testSeed(seed,25000) end
print("STATEFUL",operations,checks)
