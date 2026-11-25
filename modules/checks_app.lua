function run(root, dir)
	if os.execv("sh", { "-c", "command -v cage >/dev/null 2>&1" }, { try = true }) ~= 0
		or os.execv("sh", { "-c", "command -v quickshell >/dev/null 2>&1" }, { try = true }) ~= 0 then
		print("app check skipped: needs cage and quickshell")
		return true
	end
	local bad_words = {
		"ERROR", "caused by", "is not a type", "TypeError", "ReferenceError", "Cannot assign", "non-existent",
		"Binding loop", "Unable to assign", "is not defined", "Cannot read property",
	}
	local failures = 0
	local entries = {}
	for _, entry in ipairs(os.files(path.join(dir, "app-*.qml"))) do
		entries[#entries + 1] = { file = entry, isolated = false }
	end
	entries[#entries + 1] = { file = path.join(dir, "shell.qml"), isolated = true }
	for _, item in ipairs(entries) do
		local envs = os.getenvs()
		envs.WLR_BACKENDS = "headless"
		envs.WLR_LIBINPUT_NO_DEVICES = "1"
		envs.WLR_RENDERER = "pixman"
		envs.YUDAE_VM = nil
		local runtime
		if item.isolated then
			envs.HYPRLAND_INSTANCE_SIGNATURE = nil
			envs.WAYLAND_DISPLAY = nil
			runtime = path.join(os.tmpdir(), "app-check-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000)))
			os.mkdir(runtime)
			envs.XDG_RUNTIME_DIR = runtime
		end
		local command = string.format("cage -- timeout 6 quickshell -p '%s' 2>&1 || true", item.file)
		local out, err = os.iorunv("sh", { "-c", command }, { curdir = root, envs = envs })
		if runtime then
			os.rm(runtime)
		end
		local bad = {}
		local loaded = false
		for line in ((out or "") .. "\n" .. (err or "")):gmatch("([^\n]*)\n") do
			if not line:lower():find("intercept", 1, true) then
				if line:find("Configuration Loaded", 1, true) then
					loaded = true
				end
				local hit = false
				for _, word in ipairs(bad_words) do
					if line:find(word, 1, true) then
						hit = true
						break
					end
				end
				if hit or line:match("Type%s+%w+%s+unavailable") then
					bad[#bad + 1] = line:gsub("^%s+", ""):gsub("%s+$", "")
				end
			end
		end
		local name = path.filename(item.file)
		if #bad > 0 or not loaded then
			failures = failures + 1
			print(name .. ": " .. (not loaded and "did not load" or "runtime errors"))
			for index = 1, math.min(12, #bad) do
				print("  " .. bad[index])
			end
		else
			print(name .. ": loads clean")
		end
	end
	if failures > 0 then
		return false
	end
	return true
end
