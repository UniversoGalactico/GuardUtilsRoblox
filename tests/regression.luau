local function eq(a,b,label)
	if a ~= b then error((label or "assert")..": expected "..tostring(b)..", got "..tostring(a),2) end
end
local count=0
local function test(name,fn)
	Guard.Stop(); clock=0; fn(); count+=1; print("PASS "..name)
end
test("primitive, cycles, invalid options",function()
	eq(Guard.validateData({a=true,b="text"}),true)
	eq(Guard.validateData(0/0),false)
	eq(Guard.validateData(math.huge),false)
	local a={};a.x=a
	local ok,code=Guard.validateData(a);eq(ok,false);eq(code,"CYCLIC_REFERENCE")
	eq(Guard.validateData({},false),false)
	eq(Guard.validateData({}, {MaxDepth=false}),false)
	eq(Guard.validateData({}, {MaxDepth=100000}),false)
	eq(Guard.isDataStoreSafe({}, {MaxTotalNodes=false}),false)
	eq(Guard.validateData("\255"),false)
end)
test("alias depth and total budget",function()
	local leaf={child={n=1}}
	local ok,code=Guard.validateData({a=leaf,b={next=leaf}},{MaxDepth=3})
	eq(ok,false);eq(code,"MAX_DEPTH_EXCEEDED")
	ok,code=Guard.validateData({a=leaf,b=leaf},{MaxTotalNodes=5})
	eq(ok,false);eq(code,"MAX_TOTAL_NODES_EXCEEDED")
	eq(Guard.validateData({a="123",b="456"},{MaxTotalBytes=7}),false)
	local dag={n=1}
	for _=1,16 do dag={a=dag,b=dag} end
	eq(Guard.validateData(dag,{MaxDepth=32,MaxTotalNodes=1000}),false)
end)
test("strict shape and metamethods",function()
	eq(Guard.isDataStoreSafe({[2]=1}),false)
	eq(Guard.isDataStoreSafe({[1]=1,a=2}),false)
	eq(Guard.isDataStoreSafe({1,2}),true)
	local key=setmetatable({}, {__tostring=function() error("unsafe") end})
	eq(Guard.validateData({[key]=1}),false)
end)
test("sanitizers",function()
	eq(Guard.sanitizeNumber(5.9,0,10),5)
	eq(Guard.sanitizeNumber(20,0,10,{Clamp=true}),10)
	eq(Guard.sanitizeNumber(3,false,10),nil)
	eq(Guard.sanitizeNumber(0,0.2,0.8,{Clamp=true}),nil)
	eq(Guard.sanitizeNumber(0,0.2,3.8,{Clamp=true}),1)
	eq(Guard.sanitizeString("  hola\0  "),"hola")
	eq(Guard.sanitizeString("a",false),nil)
end)
test("rate boundaries and policy",function()
	eq(Guard.isRateLimited("a",2,1),false);eq(Guard.isRateLimited("a",2,1),false)
	eq(Guard.isRateLimited("a",2,1),true)
	local limited,code=Guard.isRateLimited("a",2,2)
	eq(limited,true);eq(code,"RATE_LIMIT_POLICY_MISMATCH")
	eq(Guard.isRateLimited("a",3,1),true)
	clock=.999;eq(Guard.isRateLimited("a",2,1),true)
	clock=1;eq(Guard.isRateLimited("a",2,1),false)
	eq(Guard.GetStats().RateLimitTimestamps,1)
	Guard.cleanupRateLimitPrefix("a");eq(Guard.GetStats().RateLimitTimestamps,0)
	eq(Guard.isRateLimited("a",false,1),true)
	eq(Guard.isRateLimited("a",1001,1),true)
end)
test("rate differential model: 15000 transitions",function()
	local model={};local seed=7919
	for i=1,15000 do
		seed=(seed*16807)%2147483647
		clock+=(seed%5)/10
		local k="k"..(seed%37)
		local q=model[k] or {};model[k]=q
		while q[1] and clock-q[1]>=1 do table.remove(q,1) end
		local expected=#q>=3
		eq(Guard.isRateLimited(k,3,1),expected,"step "..i)
		if not expected then table.insert(q,clock) end
		if i%17==0 then Guard.runMaintenance() end
		if i%101==0 then Guard.cleanupRateLimit(k);model[k]=nil end
	end
end)
test("rate compaction and accounting",function()
	for i=1,1000 do
		clock=i
		eq(Guard.isRateLimited("hot",100,100),false)
		eq(Guard.GetStats().RateLimitTimestamps,math.min(i,100))
	end
	Guard.cleanupRateLimit("hot")
	eq(Guard.GetStats().RateLimitTimestamps,0)
end)
test("rate total capacity and recovery",function()
	for k=1,100 do for _=1,1000 do eq(Guard.isRateLimited("cap"..k,1000,10),false) end end
	eq(Guard.GetStats().RateLimitTimestamps,100000)
	local limited,code=Guard.isRateLimited("overflow",1,1)
	eq(limited,true);eq(code,"RATE_LIMIT_TIMESTAMP_CAPACITY_REACHED")
	Guard.cleanupRateLimit("cap1");eq(Guard.GetStats().RateLimitTimestamps,99000)
	eq(Guard.isRateLimited("overflow",1,1),false)
end)
test("rate lifecycle and maintenance",function()
	eq(Guard.isRateLimited("idle",1,1),false)
	clock=121;eq(Guard.runMaintenance(),true)
	eq(Guard.GetStats().RateLimitKeys,0);eq(Guard.GetStats().RateLimitTimestamps,0)
	Guard.Stop(false);eq(Guard.GetStats().Running,false)
	eq(Guard.isRateLimited("again",1,1),false);eq(Guard.GetStats().Running,true)
end)
test("lease stale renewal and release",function()
	local locks={};local a=assert(Guard.acquireMutex(locks,1,2))
	eq(Guard.ownsMutex(locks,1,a),true);eq(Guard.releaseMutex(locks,1,"wrong"),false)
	clock=2;local ok,code=Guard.renewMutex(locks,1,a,2)
	eq(ok,false);eq(code,"LOCK_EXPIRED")
	local b=assert(Guard.acquireMutex(locks,1,2))
	eq(a==b,false);eq(Guard.releaseMutex(locks,1,a),false)
	eq(Guard.renewMutex(locks,1,b,2),true);eq(Guard.releaseMutex(locks,1,b),true)
end)
test("lease differential model: 10000 transitions",function()
	local locks,model={},{}
	local seed=17041
	for i=1,10000 do
		seed=(seed*16807)%2147483647
		clock+=(seed%3)/10
		local key=seed%23
		local op=math.floor(seed/23)%4
		local record=model[key]
		local live=record and clock<record.deadline
		if op==0 then
			local token=Guard.acquireMutex(locks,key,2)
			eq(token~=nil,not live,"acquire "..i)
			if token then model[key]={token=token,deadline=clock+2} end
		elseif op==1 and record then
			local result=Guard.renewMutex(locks,key,record.token,2)
			eq(result,not not live,"renew "..i)
			if result then record.deadline=clock+2 end
		elseif op==2 and record then
			local result=Guard.releaseMutex(locks,key,record.token)
			eq(result,not not live,"release "..i)
			model[key]=nil
		else
			eq(Guard.isMutexLocked(locks,key),not not live,"locked "..i)
		end
		if i%19==0 then Guard.runMaintenance() end
	end
end)
test("synchronous critical section",function()
	local locks={}
	local r=table.pack(Guard.withMutex(locks,1,function(token)
		eq(Guard.ownsMutex(locks,1,token),true);return 7,nil,9
	end))
	eq(r.n,4);eq(r[1],true);eq(r[2],7);eq(r[3],nil);eq(r[4],9)
	local ok,code=Guard.withMutex(locks,1,function() error("boom") end)
	eq(ok,false);eq(code,"CALLBACK_ERROR")
	ok,code=Guard.withMutex(locks,1,function() coroutine.yield() end)
	eq(ok,false);eq(code,"CALLBACK_YIELDED");eq(Guard.isMutexLocked(locks,1),false)
end)
test("frozen tables and expiry",function()
	eq(Guard.acquireMutex(table.freeze({}),1),nil)
	local locks={};local a=assert(Guard.acquireMutex(locks,1,1))
	clock=1;local ok,code=Guard.releaseMutex(locks,1,a);eq(ok,false);eq(code,"LOCK_EXPIRED")
end)
test("copy cycles, aliases and deep chains",function()
	local k={};local a={x=k,y=k};a[k]=a;a.self=a
	local b=assert(Guard.deepCopy(a))
	eq(b==a,false);eq(b.x,b.y);eq(b[b.x],b);eq(b.self,b)
	local root={};local cur=root
	for _=1,3000 do cur.next={};cur=cur.next end
	local copy=assert(Guard.deepCopy(root))
	for _=1,3000 do copy=copy.next end
	eq(type(copy),"table")
end)
test("private namespaces isolate caller data and reject live unregister",function()
	local locks={unrelated="preserved"}
	local id=assert(Guard.registerMutexTable(locks,10))
	local token=assert(Guard.acquireMutex(locks,"x",2))
	eq(locks.x,nil)
	locks.x={Token="forged",ExpiresAt=1000}
	eq(Guard.ownsMutex(locks,"x",token),true)
	eq(Guard.ownsMutex(locks,"x","forged"),false)
	eq(Guard.acquireMutex(locks,"x"),nil)
	local ok,code=Guard.unregisterMutexTable(id)
	eq(ok,false);eq(code,"ACTIVE_LEASES")
	clock=2
	eq(Guard.unregisterMutexTable(id),true)
	eq(Guard.GetStats().MutexRecords,0)
	eq(Guard.GetStats().MutexRegistrations,0)
	eq(locks.unrelated,"preserved")
	eq(locks.x.Token,"forged")
	local nextToken=assert(Guard.acquireMutex(locks,"x"))
	Guard.Stop()
	eq(Guard.ownsMutex(locks,"x",nextToken),false)
	eq(locks.x.Token,"forged")
end)
test("namespace default and per-lease overrides",function()
	local locks={}
	Guard.registerMutexTable(locks,10)
	local a=assert(Guard.acquireMutex(locks,"a",1))
	local b=assert(Guard.acquireMutex(locks,"b"))
	clock=1
	eq(Guard.ownsMutex(locks,"a",a),false)
	eq(Guard.ownsMutex(locks,"b",b),true)
	clock=10
	eq(Guard.ownsMutex(locks,"b",b),false)
	eq(Guard.acquireMutex(locks,string.rep("k",201)),nil)
end)
test("mutex capacity accounting and recovery",function()
	local namespaces={}
	for n=1,32 do
		local locks={};namespaces[n]=locks
		for k=1,1024 do assert(Guard.acquireMutex(locks,k,10)) end
		local token,code=Guard.acquireMutex(locks,1025,10)
		eq(token,nil);eq(code,"MUTEX_NAMESPACE_CAPACITY_REACHED")
	end
	eq(Guard.GetStats().MutexRecords,32768)
	eq(Guard.GetStats().ActiveMutexes,32768)
	local overflow={}
	local token,code=Guard.acquireMutex(overflow,1,10)
	eq(token,nil);eq(code,"MUTEX_RECORD_CAPACITY_REACHED")
	clock=10;eq(Guard.runMaintenance(),true)
	eq(Guard.GetStats().MutexRecords,0)
	assert(Guard.acquireMutex(overflow,1,10))
	eq(Guard.GetStats().MutexRecords,1)
end)
test("rate denied request restarts stopped maintenance",function()
	eq(Guard.isRateLimited("x",1,10),false)
	Guard.Stop(false)
	eq(Guard.GetStats().Running,false)
	eq(Guard.isRateLimited("x",1,10),true)
	eq(Guard.GetStats().Running,true)
end)
test("callback cannot falsely report retained ownership after Stop",function()
	local locks={}
	local ok,code=Guard.withMutex(locks,1,function()
		Guard.Stop()
		assert(Guard.acquireMutex(locks,1))
	end)
	eq(ok,false);eq(code,"LOCK_OWNERSHIP_LOST")
	eq(Guard.isMutexLocked(locks,1),true)
end)
print("PASS "..count.." suites")
