function run(root, dir, out)
	import("core.base.option")
	local args = table.wrap(option.get("args") or {})
	local seconds = tostring(option.get("seconds") or "5")
	local verb = (args[1] == "disk" or args[1] == "files" or args[1] == "wallpaper") and args[1] or nil
	os.execv("xmake", { "build", "yudaemond" }, { curdir = root })
	local full = path.join(out, "yudaemond")
	local headless = path.join(out, "yudaemond-headless")
	if verb then
		local rest = { "bench", verb }
		for index = 2, #args do
			rest[#rest + 1] = args[index]
		end
		if option.get("cold") then rest[#rest + 1] = "--cold" end
		if option.get("real") then rest[#rest + 1] = "--real" end
		if option.get("files") then rest[#rest + 1] = "--files=" .. tostring(option.get("files")) end
		os.execv(full, rest, { curdir = root })
		return
	end
	local full_out = os.iorunv(full, { "bench", "--json", "--seconds", seconds }, { curdir = root })
	local function field(name)
		local value = full_out and full_out:match('"' .. name .. '":(%d+)')
		return tonumber(value or "0")
	end
	local full_idle = field("idleRssKb")
	os.execv("sh", { "-c", "xmake f --headless=y -y >/dev/null" }, { curdir = root })
	os.rm(path.join(path.directory(out), "zig-cache-headless"))
	local started = os.mclock()
	os.execv("xmake", { "build", "yudaemond-headless" }, { curdir = root })
	local cold_ms = os.mclock() - started
	os.execv("sh", { "-c", "xmake f --headless=n -y >/dev/null" }, { curdir = root })
	local runtime = path.join(os.tmpdir(), "ydheadless-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000)))
	os.mkdir(runtime)
	local envs = os.getenvs()
	envs.XDG_RUNTIME_DIR = runtime
	local pid = os.iorunv("sh", { "-c", string.format("'%s' run >/dev/null 2>&1 & echo $!", headless) }, { envs = envs, curdir = root })
	local socket_path = path.join(runtime, "yudaemond.sock")
	local deadline = os.mclock() + 10000
	while os.mclock() < deadline and not os.isfile(socket_path) do
		os.sleep(0.02)
	end
	local failed = false
	if not os.isfile(socket_path) then
		print("FAIL headless daemon did not open its socket")
		failed = true
	else
		local probe, probe_err = os.iorunv(full, { "bench", "--json", "--seconds", seconds }, { envs = envs, curdir = root })
		local listen = tonumber(probe and probe:match('"listenMs":(%d+)') or "0") or 0
		local idle = tonumber(probe and probe:match('"idleRssKb":(%d+)') or "0") or 0
		local size = os.filesize(headless) or 0
		local gates = {
			{ "cold build", cold_ms, 20000, "ms" },
			{ "headless binary", size, 3 * 1024 * 1024, "B" },
			{ "headless start", listen, 10, "ms" },
			{ "headless idle rss", idle, 8 * 1024, "kB" },
		}
		for _, gate in ipairs(gates) do
			local state = gate[2] <= gate[3] and "ok  " or "FAIL"
			if gate[2] > gate[3] then failed = true end
			print(string.format("%s %-20s %10d %s  budget %d", state, gate[1], gate[2], gate[4], gate[3]))
		end
		local spawn, spawn_err = os.iorunv(full, { "spawn-check", "--seconds", seconds }, { envs = envs, curdir = root })
		if spawn then
			print("ok   headless spawns    " .. spawn:gsub("%s+$", ""))
		else
			failed = true
			print("FAIL headless spawns    " .. tostring(spawn_err or ""))
		end
		print(string.format("info full daemon idle rss %d kB (not a gate)", full_idle))
	end
	os.execv("sh", { "-c", "kill -TERM " .. pid .. " 2>/dev/null || true" })
	os.sleep(0.2)
	os.rm(runtime)
	if failed then
		print("bench over budget")
		raise("bench over budget")
	end
	print("bench within budget")
end
