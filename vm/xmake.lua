-- vm image task, host doctor, image bench

local dir = os.scriptdir()
local root = path.directory(dir)

task("vm")
	set_category("action")
	set_menu {
		usage = "xmake vm fetch|packages|golden|ensure|overlay|snapshot|restore|list|bench [tag]",
		description = "build and bench vm images",
		options = {
			{ nil, "args", "vs", nil, "vm arguments" },
			{ nil, "force", "k", nil, "force the vm image step" },
			{ nil, "snapshot", "kv", nil, "pin the Arch Linux Archive date" },
		}
	}
	on_run(function ()
		local function trim(text)
			return ((text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
		end

		local function capture(command)
			return trim(os.iorunv("sh", { "-c", command }))
		end

		local function run_images(args)
			os.execv(path.join(dir, "images"), args, { curdir = root })
		end

		local function bench_images(tag)
			tag = tag or "local"
			tag = tag:gsub('"', "")
			local bench = os.getenv("DOTFILES_VM_BENCH") or path.join(os.getenv("HOME"), ".cache", "yudae-vm-bench")
			local cache_home = os.getenv("DOTFILES_VM_BENCH_CACHE") or path.join(bench, "cache")
			local runs = os.getenv("DOTFILES_VM_RUNS") or path.join(bench, "runs")
			local cache = path.join(cache_home, "dotfiles", "vm")
			local logs = path.join(bench, "logs")
			os.mkdir(cache)
			os.mkdir(logs)
			os.mkdir(path.join(root, "bench"))

			local envs = os.getenvs()
			envs.XDG_CACHE_HOME = cache_home
			envs.DOTFILES_VM_RUNS = runs

			local function phase(name, args)
				local started = os.mclock()
				local log = path.join(logs, name .. ".log")
				local command = string.format("'%s' %s >'%s' 2>&1", path.join(dir, "images"), table.concat(args, " "), log)
				local code = os.execv("sh", { "-c", command }, { curdir = root, envs = envs, try = true })
				if code ~= 0 then
					raise("bench failed, see " .. logs)
				end
				return os.mclock() - started
			end

			local fetch_ms = phase("fetch", { "fetch" })
			local packages_ms = phase("packages", { "packages", "--force" })
			local golden_ms = phase("golden", { "golden", "--force" })
			local total = fetch_ms + packages_ms + golden_ms
			local packages_mb = capture(string.format("du -sm '%s' '%s' 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'",
				path.join(cache, "packages.qcow2"), path.join(cache, "packages.raw")))
			local golden_mb = capture(string.format("du -sm '%s' 2>/dev/null | cut -f1", path.join(cache, "golden.qcow2")))

			local line = string.format('{"at":%d,"tag":"%s","fetchMs":%d,"packagesMs":%d,"goldenMs":%d,"totalMs":%d,"packagesMb":%s,"goldenMb":%s}',
				os.time(), tag, fetch_ms, packages_ms, golden_ms, total, packages_mb ~= "" and packages_mb or "0", golden_mb ~= "" and golden_mb or "0")
			local logfile = path.join(root, "bench", "images.jsonl")
			io.writefile(logfile, (io.readfile(logfile) or "") .. line .. "\n")
			print(line)

			local function show(ms)
				return string.format("%dm%02ds", math.floor(ms / 60000), math.floor(ms / 1000) % 60)
			end
			print(string.format("fetch %s  packages %s  golden %s  total %s  packages %sMB  golden %sMB",
				show(fetch_ms), show(packages_ms), show(golden_ms), show(total),
				packages_mb ~= "" and packages_mb or "0", golden_mb ~= "" and golden_mb or "0"))
		end
		import("core.base.option")
		local args = table.wrap(option.get("args") or {})
		if #args == 0 then
			print("usage: xmake vm fetch|packages|golden|ensure|overlay|snapshot|restore|list|bench [tag] (running VMs: yudae vm)")
			raise("missing vm verb")
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
	end)

task("doctor")
	set_category("action")
	set_menu {
		usage = "xmake doctor [--json]",
		description = "check the host and the vm toolchain",
		options = {
			{ nil, "args", "vs", nil, "arguments" },
			{ 'j', "json", "k", nil, "print the vm checks as json" },
		}
	}
	on_run(function ()
		import("core.base.option")
		local json = option.get("json") and true or false

		local function trim(text)
			return ((text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
		end

		local function capture(command)
			return trim(os.iorunv("sh", { "-c", command }))
		end

		local missing = 0
		if not json then
			for _, tool in ipairs({ "zig", "xmake", "make", "qemu-system-x86_64", "qemu-img" }) do
				local path_ = capture("command -v " .. tool)
				if path_ ~= "" then
					print("ok   " .. tool .. " " .. path_)
				else
					print("miss " .. tool)
					missing = 1
				end
			end
			for _, path_ in ipairs({ "/usr/lib/virtiofsd", "/dev/kvm", "/dev/vhost-vsock", "/dev/dri/renderD128" }) do
				if os.exists(path_) then
					print("ok   " .. path_)
				else
					print("miss " .. path_)
					missing = 1
				end
			end
			local daemon = path.join(root, "daemon", "zig-out", "bin", "yudaemond")
			if os.isfile(daemon) then
				print("ok   daemon " .. daemon)
			else
				print("miss daemon binary")
				missing = 1
			end
			local enabled = os.execv("systemctl", { "--user", "is-enabled", "yudaemond" }, { try = true, stdout = "/dev/null", stderr = "/dev/null" })
			if enabled == 0 then
				print("ok   yudaemond.service")
			else
				print("miss yudaemond.service")
				missing = 1
			end
			print("")
		end

		local rows = {}
		local fail, warn = 0, 0
		local function row(name, status, detail, fix)
			rows[#rows + 1] = { name = name, status = status, detail = detail, fix = fix }
			if status == "fail" then fail = fail + 1 end
			if status == "warn" then warn = warn + 1 end
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
		local golden = path.join(os.getenv("XDG_CACHE_HOME") or path.join(os.getenv("HOME"), ".cache"), "dotfiles", "vm", "golden.qcow2")

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
				row("driver", "fail", driver .. " has no ABI table", "run xmake vm abi, then rebuild conduit-backend")
			else
				row("driver", "warn", driver .. ", Conduit not installed", "install Conduit and generate its ABI tables")
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
				row("conduit." .. pair[1], "fail", "missing " .. pair[2], "install the Conduit package")
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

		for _, path_ in ipairs({ "/dev/kvm", "/dev/dri/renderD128", "/usr/lib/virtiofsd" }) do
			if os.exists(path_) then
				row("host." .. path_, "ok", path_, "")
			else
				row("host." .. path_, "fail", "missing " .. path_, "enable KVM/render node or install virtiofsd")
			end
		end

		if os.exists(golden) then
			local listed = os.execv("grep", { "-qx", "conduit-guest", path.join(root, "vm", "packages.txt") }, { try = true, stdout = "/dev/null", stderr = "/dev/null" })
			if listed == 0 then
				row("golden", "ok", golden, "")
			else
				row("golden", "fail", "golden manifest has no conduit-guest", "add conduit-guest to vm/packages.txt and rebuild the golden image")
			end
		else
			row("golden", "fail", "no golden image", "run xmake vm golden")
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
	end)
