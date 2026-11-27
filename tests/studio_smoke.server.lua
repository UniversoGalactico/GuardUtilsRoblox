--!nonstrict
-- Run ONLY with an isolated copy of GuardUtils, in a blank Studio place.
-- Folder must contain this Script and a ModuleScript named GuardUtils.
local Guard = require(script.Parent:WaitForChild("GuardUtils"))
local passed, failed = 0, 0
local function check(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("[GuardUtils PASS] " .. name)
	else
		failed += 1
		warn("[GuardUtils FAIL] " .. name .. ": " .. tostring(err))
	end
end
local function equal(a, b)
	assert(a == b, "Expected " .. tostring(b) .. ", got " .. tostring(a))
end

print("[GuardUtils] Studio smoke test: " .. Guard.VERSION)
Guard.Stop()
check("valid and cyclic data", function()
	equal(Guard.isDataStoreSafe({Coins=100, Items={"Sword","Potion"}}), true)
	local cycle={}; cycle.self=cycle
	equal(Guard.validateData(cycle), false)
	equal(Guard.isDataStoreSafe({[2]="gap"}), false)
	equal(Guard.validateData({}, {MaxDepht=1}), false)
end)
check("string and number boundaries", function()
	equal(Guard.sanitizeString("  hola  "), "hola")
	equal(Guard.sanitizeString(string.char(195,0,169)), nil)
	equal(Guard.sanitizeNumber(10.9,0,10), nil)
	equal(Guard.sanitizeNumber(10.9,0,10,{Clamp=true}), 10)
	equal(Guard.sanitizeNumber(0/0), nil)
end)
check("rate limit and stable policy", function()
	equal(Guard.isRateLimited("smoke:rate",2,30), false)
	equal(Guard.isRateLimited("smoke:rate",2,30), false)
	equal(Guard.isRateLimited("smoke:rate",2,30), true)
	local limited, code=Guard.isRateLimited("smoke:rate",3,30)
	equal(limited,true); equal(code,"RATE_LIMIT_POLICY_MISMATCH")
	Guard.cleanupRateLimit("smoke:rate")
end)
check("live clock rate expiration", function()
	equal(Guard.isRateLimited("smoke:expiry",1,0.1),false)
	task.wait(0.2)
	equal(Guard.isRateLimited("smoke:expiry",1,0.1),false)
	Guard.cleanupRateLimit("smoke:expiry")
end)
check("lease ownership, renewal, release", function()
	local namespace=table.freeze({})
	local token=assert(Guard.acquireMutex(namespace,1,30))
	equal(Guard.ownsMutex(namespace,1,token),true)
	equal(Guard.acquireMutex(namespace,1,30),nil)
	equal(Guard.releaseMutex(namespace,1,"wrong"),false)
	equal(Guard.renewMutex(namespace,1,token,30),true)
	equal(Guard.releaseMutex(namespace,1,token),true)
	equal(Guard.unregisterMutexTable(namespace),true)
end)
check("synchronous critical section", function()
	local namespace={}
	local ok,a,b,c=Guard.withMutex(namespace,1,function() return 7,nil,9 end)
	equal(ok,true); equal(a,7); equal(b,nil); equal(c,9)
	equal(Guard.isMutexLocked(namespace,1),false)
	local failedOk,code=Guard.withMutex(namespace,1,function() error("expected") end)
	equal(failedOk,false); equal(code,"CALLBACK_ERROR")
	equal(Guard.unregisterMutexTable(namespace),true)
end)
check("real task.wait cancellation", function()
	local namespace={}
	local resumed=false
	local ok,code=Guard.withMutex(namespace,1,function()
		task.wait(0.15)
		resumed=true
	end)
	equal(ok,false); equal(code,"CALLBACK_YIELDED")
	task.wait(0.3)
	equal(resumed,false)
	equal(Guard.isMutexLocked(namespace,1),false)
	equal(Guard.unregisterMutexTable(namespace),true)
end)
check("watchdog expires lease automatically", function()
	local namespace={}
	local token=assert(Guard.acquireMutex(namespace,1,0.1))
	local deadline=os.clock()+5
	repeat task.wait(0.1) until Guard.GetStats().MutexRecords == 0 or os.clock()>=deadline
	equal(Guard.ownsMutex(namespace,1,token),false)
	equal(Guard.GetStats().MutexRecords,0)
	equal(Guard.unregisterMutexTable(namespace),true)
end)
check("copy graph and GUID", function()
	local shared={x=1}
	local original={a=shared,b=shared}; original.self=original
	local copy=assert(Guard.deepCopy(original))
	assert(copy~=original and copy.a~=shared)
	equal(copy.a,copy.b); equal(copy.self,copy)
	assert(Guard.generarId("test")~=Guard.generarId("test"))
end)
check("real watchdog restart and cleanup", function()
	for _=1,20 do equal(Guard.Stop(false),true); equal(Guard.Start(),true) end
	equal(Guard.Stop(),true)
	local stats=Guard.GetStats()
	equal(stats.Running,false); equal(stats.MutexRecords,0); equal(stats.RateLimitTimestamps,0)
end)
Guard.Stop()
local summary=string.format("[GuardUtils] RESULT: %d/%d PASS; %d FAIL",passed,passed+failed,failed)
if failed==0 then print(summary) else warn(summary) end
