local util = import("util")
local trim = util.trim
local capture = util.capture
function vm(dir, root)
	local function run_images(args)
		os.execv(path.join(dir, "images"), args, { curdir = root })
	end
	local function bench_images(tag)
		tag = (tag or "local"):gsub('"', "")
		local bench = os.getenv("DOTFILES_VM_BENCH") or path.join(os.getenv("HOME"), ".cache", "yudae-vm-bench")
		local cache_home = os.getenv("DOTFILES_VM_BENCH_CACHE") or path.join(bench, "cache")
		local logs = path.join(bench, "logs")
		os.mkdir(logs)
		os.mkdir(path.join(root, "bench"))
		local envs = os.getenvs()
		envs.XDG_CACHE_HOME = cache_home
		envs.DOTFILES_VM_RUNS = os.getenv("DOTFILES_VM_RUNS") or path.join(bench, "runs")
		local started = os.mclock()
		local log = path.join(logs, "build.log")
		local code = os.execv("sh", { "-c", string.format("'%s' build --force >'%s' 2>&1", path.join(dir, "images"), log) }, { curdir = root, envs = envs, try = true })
		if code ~= 0 then
			raise("bench failed, see " .. log)
		end
		local build_ms = os.mclock() - started
		local image_mb = capture(string.format("du -sm \"$(readlink -f '%s')\" | cut -f1", path.join(cache_home, "dotfiles", "vm", "images", "current")))
		local line = string.format('{"at":%d,"tag":"%s","buildMs":%d,"imageMb":%s}', os.time(), tag, build_ms, image_mb ~= "" and image_mb or "0")
		local logfile = path.join(root, "bench", "images.jsonl")
		io.writefile(logfile, (io.readfile(logfile) or "") .. line .. "\n")
		print(line)
		print(string.format("build %dm%02ds  image %sMB", math.floor(build_ms / 60000), math.floor(build_ms / 1000) % 60, image_mb))
	end
	import("core.base.option")
	local args = table.wrap(option.get("args") or {})
	if #args == 0 then
		print("usage: xmake vm images|conduit|ensure|overlay|snapshot|restore|backup|list|bench [tag] (running VMs: yudae vm)")
		raise("missing vm verb")
	end
	if args[1] == "conduit" then
		os.execv(path.join(dir, "conduit"), {}, { curdir = root })
		return
	end
	if args[1] == "bench" then
		bench_images(args[2])
		return
	end
	if option.get("force") then
		args[#args + 1] = "--force"
	end
	if option.get("snapshot") then
		args[#args + 1] = "--snapshot"
		args[#args + 1] = tostring(option.get("snapshot"))
	end
	run_images(args)
end
function doctor(dir, root)
	import("core.base.option")
	local json = option.get("json") and true or false
	local missing = 0
	if not json then
		local function mark(ok, label)
			print((ok and "ok   " or "miss ") .. label)
			if not ok then missing = 1 end
		end
		for _, tool in ipairs({ "zig", "xmake", "make", "qemu-system-x86_64", "qemu-img", "mkosi", "pasta", "nft", "unshare" }) do
			mark(capture("command -v " .. tool) ~= "", tool)
		end
		for _, path_ in ipairs({ "/usr/lib/virtiofsd", "/usr/bin/passt", "/dev/kvm", "/dev/vhost-vsock", "/dev/dri/renderD128" }) do
			mark(os.exists(path_), path_)
		end
		mark(os.isfile(path.join(root, "build", "bin", "yudaemond")), "daemon binary")
		mark(os.execv("systemctl", { "--user", "is-enabled", "yudaemond" }, { try = true, stdout = "/dev/null", stderr = "/dev/null" }) == 0, "yudaemond.service")
		print("")
	end
	local rows = {}
	local fail, warn = 0, 0
	local function row(name, status, detail, fix)
		rows[#rows + 1] = { name = name, status = status, detail = detail, fix = fix }
		if status == "fail" then fail = fail + 1 end
		if status == "warn" then warn = warn + 1 end
	end
	local function expectPath(name, path_, status, fix)
		if os.exists(path_) then row(name, "ok", path_, "") else row(name, status, "missing " .. path_, fix) end
	end
	local gpu = capture("nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1")
	local driver = capture("nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1")
	local bar1 = capture("nvidia-smi -q 2>/dev/null | awk -F: '/BAR1 Memory Usage/ {bar=1} bar && /Total/ {gsub(/^ +| MiB$/, \"\", $2); print $2; exit}'")
	local prefix = os.getenv("CONDUIT_PREFIX") or "/opt/conduit"
	local qemu = path.join(prefix, "bin", "qemu-system-x86_64")
	local backend = path.join(prefix, "bin", "conduit-backend")
	local viewer = path.join(prefix, "bin", "conduit-viewer")
	local userspace = path.join(prefix, "bin", "conduit-userspace")
	local supported = path.join(prefix, "share", "conduit", "supported-drivers.txt")
	local golden = path.join(os.getenv("XDG_CACHE_HOME") or path.join(os.getenv("HOME"), ".cache"), "dotfiles", "vm", "images", "current", "golden.qcow2")
	if gpu ~= "" then
		row("gpu", "ok", gpu, "")
	else
		row("gpu", "fail", "no NVIDIA GPU", "use the GL backend")
	end
	if driver ~= "" then
		local known = os.execv("grep", { "-qxF", driver, supported }, { try = true, stdout = "/dev/null", stderr = "/dev/null" })
		if os.isfile(supported) and known == 0 then
			row("driver", "ok", driver, "")
		elseif os.isfile(supported) then
			row("driver", "fail", driver .. " has no ABI table", "run xmake vm conduit")
		else
			row("driver", "warn", driver .. ", Conduit not installed", "run xmake vm conduit")
		end
	else
		row("driver", "warn", "not detected", "")
	end
	local fork = path.join(os.getenv("HOME"), "qemu-linux", "install", "bin", "qemu-system-x86_64")
	if os.exists(fork) then
		row("qemu.fork", "ok", fork, "")
	else
		row("qemu.fork", "fail", "missing QEMU fork", "build ~/qemu-linux and install it")
	end
	for _, pair in ipairs({ { "qemu", qemu }, { "backend", backend }, { "userspace", userspace } }) do
		if os.exists(pair[2]) then
			row("conduit." .. pair[1], "ok", pair[2], "")
		else
			row("conduit." .. pair[1], "fail", "missing " .. pair[2], "run xmake vm conduit")
		end
	end
	if os.exists(viewer) then
		row("conduit.viewer", "ok", viewer, "")
	else
		row("conduit.viewer", "warn", "missing " .. viewer, "optional: only the external viewer fallback needs it")
	end
	if bar1 ~= "" then
		if tonumber(bar1) and tonumber(bar1) < 1024 then
			row("bar1", "warn", bar1 .. "MiB, ReBAR off", "enable ReBAR in BIOS for a larger window; 256MiB works but is slower")
		else
			row("bar1", "ok", bar1 .. "MiB", "")
		end
	else
		row("bar1", "warn", "unknown", "")
	end
	local ovmf = capture("find /usr/share/OVMF /usr/share/edk2 /usr/share/ovmf -name 'OVMF_CODE*.fd' 2>/dev/null | head -1")
	if ovmf ~= "" then
		row("ovmf", "ok", ovmf, "")
	else
		row("ovmf", "warn", "no OVMF firmware", "install ovmf; required for the 64-bit GPU BAR")
	end
	for _, path_ in ipairs({ "/dev/kvm", "/dev/dri/renderD128", "/usr/lib/virtiofsd", "/usr/bin/passt" }) do
		expectPath("host." .. path_, path_, "fail", "enable KVM/render node or install virtiofsd and passt")
	end
	if os.exists(golden) then
		local listed = os.execv("grep", { "-q", '"conduit-guest"', path.join(path.directory(golden), "manifest.json") }, { try = true, stdout = "/dev/null", stderr = "/dev/null" })
		if listed == 0 then
			row("golden", "ok", golden, "")
		else
			row("golden", "fail", "golden manifest has no conduit-guest", "rebuild with xmake vm images on a host with /dev/nvidiactl (vm/mkosi/mkosi.profiles/nvidia.conf)")
		end
	else
		row("golden", "fail", "no golden image", "run xmake vm images")
	end
	local verdict = fail == 0 and "nvidia" or "gl"
	local function escape(text)
		return (text:gsub("\\", "\\\\"):gsub('"', '\\"'))
	end
	if json then
		local parts = {}
		for _, item in ipairs(rows) do
			parts[#parts + 1] = string.format('{"name":"%s","status":"%s","detail":"%s","fix":"%s"}',
				escape(item.name), escape(item.status), escape(item.detail), escape(item.fix))
		end
		print(string.format('{"verdict":"%s","gpu":"%s","driver":"%s","fail":%d,"warn":%d,"checks":[%s]}',
			verdict, escape(gpu), escape(driver), fail, warn, table.concat(parts, ",")))
		return
	end
	for _, item in ipairs(rows) do
		local line = string.format("%-8s %-4s %-4s %s", item.name, item.status, "", item.detail)
		if item.fix ~= "" then
			line = line .. " | " .. item.fix
		end
		print(line)
	end
	print("")
	print("verdict: " .. verdict)
	if missing ~= 0 then
		raise("doctor found missing pieces")
	end
end
