function run(root)
	local home = os.getenv("HOME")
	local failed = 0
	local function link_one(src, dst)
		if os.islink(dst) then
			if os.readlink(dst) == src then
				return
			end
			os.rm(dst)
		elseif os.exists(dst) then
			print("refused " .. dst .. ": a real file is there")
			failed = 1
			return
		end
		os.mkdir(path.directory(dst))
		os.ln(src, dst)
		print("linked " .. dst .. " -> " .. src)
	end
	local entries = os.files(path.join(root, "config", "*"))
	if os.exists(path.join(root, "config", ".claude")) then
		entries[#entries + 1] = path.join(root, "config", ".claude")
	end
	for _, entry in ipairs(entries) do
		link_one(entry, path.join(home, ".config", path.filename(entry)))
	end
	link_one(path.join(root, "hypr"), path.join(home, ".config", "hypr"))
	for _, unit in ipairs({ "yudaemond.service", "yudae-plugins.service", "yudae-plugins.path" }) do
		link_one(path.join(root, "systemd", "user", unit), path.join(home, ".config", "systemd", "user", unit))
	end
	local icons = {
		{ "shell/assets/providers/opencode.svg", ".local/share/icons/hicolor/scalable/apps/opencode.svg" },
		{ "shell/assets/providers/claude.svg", ".local/share/icons/hicolor/scalable/apps/claude.svg" },
		{ "shell/assets/providers/codex.svg", ".local/share/icons/hicolor/scalable/apps/codex.svg" },
		{ "shell/assets/providers/opencode-logo.png", ".local/share/icons/hicolor/256x256/apps/opencode.png" },
	}
	for _, icon in ipairs(icons) do
		link_one(path.join(root, icon[1]), path.join(home, icon[2]))
	end
	if failed ~= 0 then
		raise("link incomplete")
	end
end
