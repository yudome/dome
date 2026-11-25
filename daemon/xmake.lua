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

local links = { "-lc", "-lsystemd", "-lpolkit-gobject-1", "-lgio-2.0", "-lgobject-2.0", "-lglib-2.0" }

local c_sources = {
	path.join(dir, "src", "c", "notifybus.c"),
	path.join(dir, "src", "c", "traybus.c"),
	path.join(dir, "src", "c", "polkit.c"),
}

local function optimize()
	return has_config("debug") and "-ODebug" or has_config("small") and "-OReleaseSmall" or "-OReleaseSafe"
end

local function zig_argv(root, emit)
	local argv = { "build-exe", optimize() }
	if not has_config("debug") then table.insert(argv, "-fstrip") end
	if not has_config("llvm") then table.insert(argv, "-fno-llvm") end
	table.insert(argv, "--cache-dir")
	table.insert(argv, cache)
	for _, list in ipairs({ includes, links }) do
		for _, flag in ipairs(list) do
			table.insert(argv, flag)
		end
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

local started, built = {}, {}

local function log_build(target)
	local binary, start = built[target:name()], started[target:name()]
	if not binary or not start then return end
	local cache_mb = size_mb(cache)
	local ms = os.mclock() - start
	local size = os.filesize(binary) or 0
	local line = string.format('{"at":%d,"ms":%d,"binary":%d,"cache_mb":%d,"out_mb":%d,"global_mb":%d}\n',
		os.time(), ms, size, cache_mb, size_mb(path.join(dir, "zig-out")), size_mb(path.join(os.getenv("HOME") or "", ".cache", "zig")))
	os.mkdir(path.join(dir, "bench"))
	io.writefile(bench_log, (os.isfile(bench_log) and io.readfile(bench_log) or "") .. line)
	print(string.format("build %dms  binary %dB  cache %dMB", ms, size, cache_mb))
	if cache_mb > cap then
		os.rm(cache)
		print(string.format("pruned cache over %dMB", cap))
	end
end

local function daemon_target(name, source, with_c, link_yudae, deps)
	target(name)
		set_kind("phony")
		set_installdir(yudae_prefix())
		if deps then
			for _, dep in ipairs(deps) do add_deps(dep) end
		end
		before_build(function (target_)
			started[target_:name()] = os.mclock()
		end)
		on_build(function (target_)
			local binary = path.join(out, name)
			built[target_:name()] = binary
			local argv = zig_argv(path.join(dir, source), binary)
			if with_c then
				for _, flag in ipairs({ "-cflags", "-std=c11", "--" }) do table.insert(argv, flag) end
				for _, c_source in ipairs(c_sources) do table.insert(argv, c_source) end
			end
			os.execv("zig", argv)
		end)
		after_build(log_build)
		after_install(function (target_)
			local bindir = target_:installdir("bin")
			local link = path.join(bindir, "yudae")
			if link_yudae and os.isfile(link) and not os.islink(link) then
				raise("refused " .. link .. ": a real file is there")
			end
			os.mkdir(bindir)
			local tmp = path.join(bindir, name .. ".new")
			os.execv("install", { "-m", "0755", path.join(out, name), tmp })
			os.mv(tmp, path.join(bindir, name), { force = true })
			if link_yudae then
				os.rm(link)
				os.ln(path.join(bindir, name), link)
				print("installed " .. path.join(bindir, name) .. " and linked " .. link)
				if os.execv(link, { "restart" }, { try = true }) ~= 0 then
					print("yudae restart failed; run it by hand")
				end
			end
		end)
end

if has_config("headless") then
	daemon_target("yudaemond-headless", "src/headless.zig", false, false)
else
	daemon_target("yudaemond", "src/main.zig", true, true, { "launcher-index" })
end

target("daemon-tests")
	set_kind("phony")
	set_default(false)
	set_rundir(dir)
	add_tests("zig")
	on_test(function ()
		local argv = { "test", optimize(), "--cache-dir", cache }
		for _, list in ipairs({ includes, links }) do
			for _, flag in ipairs(list) do table.insert(argv, flag) end
		end
		for _, flag in ipairs({ "-cflags", "-std=c11", "--", path.join(dir, "src", "tests.zig") }) do table.insert(argv, flag) end
		for _, c_source in ipairs(c_sources) do table.insert(argv, c_source) end
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
		import("daemon_bench").run(path.directory(dir), dir, out)
	end)

target("fsd")
	set_kind("phony")
	set_default(false)
	after_install(function ()
		import("install").fsd(dir, out)
	end)
