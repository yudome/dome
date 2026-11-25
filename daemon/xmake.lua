-- yudaemond, headless daemon, zig tests, index and cover tools

local dir = os.scriptdir()
local out = path.join(dir, "zig-out", "bin")
local cache = path.join(dir, has_config("headless") and ".zig-cache-headless" or ".zig-cache")
local cap = tonumber(os.getenv("YUDA_BUILD_CACHE_MB") or "300")
local bench_log = path.join(dir, "bench", "build.jsonl")

local includes = {
	"-I" .. path.join(dir, "src", "c"),
	"-I/usr/include/polkit-1",
	"-I/usr/include/glib-2.0",
	"-I/usr/lib/glib-2.0/include",
}

local links = {
	"-lc",
	"-lsystemd",
	"-lpolkit-gobject-1",
	"-lgio-2.0",
	"-lgobject-2.0",
	"-lglib-2.0",
}

local sources = {
	path.join(dir, "src", "c", "notifybus.c"),
	path.join(dir, "src", "c", "traybus.c"),
	path.join(dir, "src", "c", "polkit.c"),
}

local function optimize()
	return has_config("debug") and "-ODebug" or has_config("small") and "-OReleaseSmall" or "-OReleaseSafe"
end

local function zig_argv(root, emit)
	local argv = { "build-exe", optimize() }
	if not has_config("debug") then
		table.insert(argv, "-fstrip")
	end
	if not has_config("llvm") then
		table.insert(argv, "-fno-llvm")
	end
	table.insert(argv, "--cache-dir")
	table.insert(argv, cache)
	for _, flag in ipairs(includes) do
		table.insert(argv, flag)
	end
	for _, flag in ipairs(links) do
		table.insert(argv, flag)
	end
	table.insert(argv, "-femit-bin=" .. emit)
	table.insert(argv, root)
	return argv
end

local function size_mb(at)
	local total = 0
	for _, file in ipairs(os.files(path.join(at, "**"))) do
		total = total + (os.filesize(file) or 0)
	end
	return math.floor(total / (1024 * 1024))
end

target("launcher-index")
	set_kind("phony")
	set_default(false)
	on_build(function ()
		local asset = path.join(dir, "assets", "launcher-index.bin.gz")
		if os.isfile(asset) then return end
		local tool = path.join(out, "build-index")
		os.execv("zig", { "build-exe", optimize(), "--cache-dir", cache, "-femit-bin=" .. tool, path.join(dir, "src", "build_index.zig") })
		os.execv(tool, { asset })
	end)

target("theme-cover")
	set_kind("phony")
	set_default(false)
	on_build(function ()
		local tool = path.join(out, "theme-cover")
		os.execv("zig", { "build-exe", optimize(), "--cache-dir", cache, "-femit-bin=" .. tool, path.join(dir, "src", "theme_cover.zig") })
	end)

local started = {}
local built = {}

local function log_build(target)
	local binary = built[target:name()]
	local start = started[target:name()]
	if not binary or not start then return end
	local cache_mb = size_mb(cache)
	local ms = os.mclock() - start
	local size = os.filesize(binary) or 0
	local line = string.format('{"at":%d,"ms":%d,"binary":%d,"cache_mb":%d,"out_mb":%d,"global_mb":%d}\n', os.time(), ms, size, cache_mb, size_mb(path.join(dir, "zig-out")), size_mb(path.join(os.getenv("HOME") or "", ".cache", "zig")))
	os.mkdir(path.join(dir, "bench"))
	io.writefile(bench_log, (io.readfile(bench_log) or "") .. line)
	print(string.format("build %dms  binary %dB  cache %dMB", ms, size, cache_mb))
	if cache_mb > cap then
		os.rm(cache)
		print(string.format("pruned cache over %dMB", cap))
	end
end

if has_config("headless") then
	target("yudaemond-headless")
		set_kind("phony")
		set_installdir(yudae_prefix())
		before_build(function (target)
			started[target:name()] = os.mclock()
		end)
		on_build(function (target)
			local binary = path.join(out, "yudaemond-headless")
			built[target:name()] = binary
			os.execv("zig", zig_argv(path.join(dir, "src", "headless.zig"), binary))
		end)
		after_build(log_build)
		after_install(function (target)
			local bindir = target:installdir("bin")
			os.mkdir(bindir)
			local tmp = path.join(bindir, "yudaemond-headless.new")
			os.execv("install", { "-m", "0755", path.join(out, "yudaemond-headless"), tmp })
			os.mv(tmp, path.join(bindir, "yudaemond-headless"), { force = true })
		end)
else
	target("yudaemond")
		set_kind("phony")
		set_installdir(yudae_prefix())
		add_deps("launcher-index")
		before_build(function (target)
			started[target:name()] = os.mclock()
		end)
		on_build(function (target)
			local binary = path.join(out, "yudaemond")
			built[target:name()] = binary
			local argv = zig_argv(path.join(dir, "src", "main.zig"), binary)
			table.insert(argv, "-cflags")
			table.insert(argv, "-std=c11")
			table.insert(argv, "--")
			for _, source in ipairs(sources) do
				table.insert(argv, source)
			end
			os.execv("zig", argv)
		end)
		after_build(log_build)
		after_install(function (target)
			local bindir = target:installdir("bin")
			local link = path.join(bindir, "yudae")
			local binary = path.join(bindir, "yudaemond")
			if os.isfile(link) and not os.islink(link) then
				raise("refused %s: a real file is there", link)
			end
			os.mkdir(bindir)
			local tmp = binary .. ".new"
			os.execv("install", { "-m", "0755", path.join(out, "yudaemond"), tmp })
			os.mv(tmp, binary, { force = true })
			os.rm(link)
			os.ln(binary, link)
			print("installed %s and linked %s", binary, link)
		end)
end

target("daemon-tests")
	set_kind("phony")
	set_default(false)
	set_rundir(dir)
	add_tests("zig")
	on_test(function ()
		local argv = { "test", optimize(), "--cache-dir", cache }
		for _, flag in ipairs(includes) do
			table.insert(argv, flag)
		end
		for _, flag in ipairs(links) do
			table.insert(argv, flag)
		end
		table.insert(argv, "-cflags")
		table.insert(argv, "-std=c11")
		table.insert(argv, "--")
		table.insert(argv, path.join(dir, "src", "tests.zig"))
		for _, source in ipairs(sources) do
			table.insert(argv, source)
		end
		os.execv("zig", argv, { curdir = dir })
		return true
	end)

task("bench")
	set_category("action")
	set_menu {
		usage = "xmake bench [disk|files] [--seconds N]",
		description = "build, measure and gate the daemon",
		options = {
			{ nil, "args", "vs", nil, "bench arguments" },
			{ 's', "seconds", "kv", nil, "seconds to measure" },
			{ nil, "cold", "k", nil, "drop the page cache for disk" },
			{ nil, "real", "k", nil, "add $HOME for disk" },
			{ nil, "files", "kv", nil, "tiny file count for disk" },
		}
	}
	on_run(function ()
		import("core.base.option")
		local args = table.wrap(option.get("args") or {})
		local seconds = tostring(option.get("seconds") or "5")
		local verb = args[1] == "disk" or args[1] == "files" and args[1] or nil

		local root = path.directory(dir)
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
		os.rm(path.join(dir, ".zig-cache-headless"))
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
	end)

target("fsd")
	set_kind("phony")
	set_default(false)
	after_install(function ()
		local uid = (os.iorunv("id", { "-u" }) or ""):gsub("%s+", "")
		if uid ~= "0" then
			raise("run as root, after deciding to install the helper")
		end
		io.write("Install yudae-fsd and its polkit action? [y/N] ")
		local answer = io.read()
		if not answer or not answer:match("^[yY]") then
			print("nothing installed")
			raise("nothing installed")
		end

		local prefix = os.getenv("PREFIX") or "/usr/local"
		local bindir = path.join(prefix, "lib", "yudae")
		local repo = path.directory(dir)
		os.execv("install", { "-d", bindir, "/usr/share/polkit-1/actions", "/usr/lib/systemd/system" })
		os.execv("install", { "-m", "0755", path.join(out, "yudaemond"), path.join(bindir, "yudaemond") })
		os.execv("install", { "-m", "0644", path.join(repo, "systemd", "system", "yudae-fsd.socket"), "/usr/lib/systemd/system/yudae-fsd.socket" })
		os.execv("install", { "-m", "0644", path.join(repo, "systemd", "system", "yudae-fsd.service"), "/usr/lib/systemd/system/yudae-fsd.service" })
		os.execv("install", { "-m", "0644", path.join(repo, "systemd", "system", "org.yudae.policy"), "/usr/share/polkit-1/actions/org.yudae.policy" })
		os.execv("systemctl", { "daemon-reload" })
		os.execv("systemctl", { "enable", "--now", "yudae-fsd.socket" })
		print("installed yudae-fsd")
	end)
