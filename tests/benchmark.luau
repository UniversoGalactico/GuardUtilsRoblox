-- Diagnostic microbenchmarks. No runtime thresholds or production guarantees.
local function benchmark(name,ops,work)
	local times={}
	for sample=0,5 do
		Guard.Stop();resetScheduler();clock=0
		local begin=realClock()
		work(ops)
		local elapsed=realClock()-begin
		if sample>0 then table.insert(times,elapsed) end
	end
	table.sort(times)
	print(string.format("BENCH %s ops=%d median_ms=%.3f ops_per_sec=%.0f",name,ops,times[3]*1000,ops/math.max(times[3],0.000001)))
end
local small={Coins=100,Inventory={{Id="Sword",Level=2},{Id="Potion",Count=3}},Stats={Health=100,Alive=true}}
local large={}
for i=1,100 do large["item"..i]={Id="item"..i,Count=i,Enabled=true} end
benchmark("validate_small",20000,function(n)
	for _=1,n do assert(Guard.validateData(small)) end
end)
benchmark("validate_large",2000,function(n)
	for _=1,n do assert(Guard.validateData(large)) end
end)
benchmark("rate_window",100000,function(n)
	for i=1,n do clock=i*0.01;Guard.isRateLimited("key"..(i%100),5,1) end
end)
benchmark("lease_pair",50000,function(n)
	local namespace={}
	for i=1,n do
		local key=i%32
		local token=assert(Guard.acquireMutex(namespace,key,30))
		assert(Guard.releaseMutex(namespace,key,token))
	end
end)
local graph={};graph.a={};graph.b=graph.a;graph.a.parent=graph
benchmark("copy_graph",20000,function(n)
	for _=1,n do assert(Guard.deepCopy(graph)) end
end)
