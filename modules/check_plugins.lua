local util = import("util")
local trim = util.trim
function run(root)
	local function strip_comment(line)
		local quoted, escaped = false, false
		for i = 1, #line do
			local c = line:sub(i, i)
			if escaped then escaped = false
			elseif c == "\\" and quoted then escaped = true
			elseif c == '"' then quoted = not quoted
			elseif c == "#" and not quoted then return line:sub(1, i - 1) end
		end
		return line
	end
	local function parse_value(raw)
		raw = trim(raw)
		if raw:sub(1, 1) == '"' and raw:sub(-1) == '"' then return raw:sub(2, -2) end
		if raw == "true" then return true end
		if raw == "false" then return false end
		local list = raw:match("^%[(.*)%]$")
		if list then
			local items = {}
			for item in list:gmatch('"([^"]*)"') do items[#items + 1] = item end
			if #items == 0 then
				for item in list:gmatch("[^,]+") do items[#items + 1] = tonumber(trim(item)) or trim(item) end
			end
			return items
		end
		return tonumber(raw) or raw
	end
	local function parse_toml(text)
		local out, current = {}, nil
		for line in (text .. "\n"):gmatch("([^\n]*)\n") do
			local code = trim(strip_comment(line))
			if code ~= "" then
				local header = code:match("^%[([^%]]+)%]$")
				if header then
					current = {}
					out[header] = current
				else
					local key, raw = code:match("^([%w_%-]+)%s*=%s*(.+)$")
					if not key then return nil, "cannot parse line " .. code end
					current = current or out
					current[key] = parse_value(raw)
				end
			end
		end
		return out
	end
	local function color_keys(root)
		local body = io.readfile(path.join(root, "shell", "services", "Config.qml")) or ""
		local keys = {}
		for name, hex in body:gmatch('settings%.(%w+) !== undefined %? settings%.%w+ : "(#[%x]+)"') do
			local size = #hex - 1
			if size == 6 or size == 8 then
				keys[name] = true
			end
		end
		return keys
	end
	local function constraint(text)
		if type(text) ~= "string" then
			return nil, "requires.hyprland must be a string"
		end
		text = trim(text)
		local operator, version = text:match("^(>=)%s*(.+)$")
		if not operator then operator, version = text:match("^(<=)%s*(.+)$") end
		if not operator then operator, version = text:match("^([<>=])%s*(.+)$") end
		if not operator then operator, version = "=", text end
		version = trim(version)
		if not version:match("^%d+%.?%d*%.?%d*$") then
			return nil, "bad requires.hyprland constraint " .. text
		end
		local parts = {}
		for part in (version .. "."):gmatch("(%d+)%.") do
			parts[#parts + 1] = tonumber(part)
		end
		return operator or "=", parts
	end
	local function parse_version(text)
		local parts = {}
		for part in text:gmatch("%d+") do
			parts[#parts + 1] = tonumber(part)
			if #parts == 3 then break end
		end
		return parts
	end
	local function satisfies(have, operator, want)
		local width = math.max(#have, #want)
		for i = #have + 1, width do have[i] = 0 end
		for i = #want + 1, width do want[i] = 0 end
		for i = 1, width do
			if have[i] ~= want[i] then
				if operator == ">=" then return have[i] > want[i] end
				if operator == "<=" then return have[i] < want[i] end
				if operator == ">" then return have[i] > want[i] end
				if operator == "<" then return have[i] < want[i] end
				return false
			end
		end
		return operator == ">=" or operator == "<=" or operator == "="
	end
	local hypr_version
	local function hyprland_version()
		if hypr_version ~= nil then return hypr_version end
		local out = os.iorunv("sh", { "-c", "pkg-config --modversion hyprland 2>/dev/null || true" })
		hypr_version = trim(out or "")
		return hypr_version
	end
	local function manifest(plugin_dir, name)
		local body = io.readfile(path.join(plugin_dir, "plugin.toml"))
		if not body then
			return nil, "missing plugin.toml"
		end
		local data, err = parse_toml(body)
		if not data then
			return nil, "bad plugin.toml: " .. err
		end
		local transition = data.kind == "transition"
		for key in pairs(data) do
			local extra = transition and (key == "duration" or key == "easing" or key == "ink_at")
			if not extra and key ~= "id" and key ~= "kind" and key ~= "version" and key ~= "requires" and key ~= "build" and key ~= "provides" then
				return nil, "unknown manifest keys: " .. key
			end
		end
		if type(data.id) ~= "string" or not data.id:match("^_?[a-z][a-z0-9%-]*$") then
			return nil, "id must match ^_?[a-z][a-z0-9-]*$"
		end
		if data.id ~= name then
			return nil, string.format("id %q does not match folder %q", data.id, name)
		end
		if data.kind ~= "hypr" and data.kind ~= "theme" and data.kind ~= "shell" and data.kind ~= "app" and data.kind ~= "daemon" and not transition then
			return nil, string.format("unknown kind %q", tostring(data.kind))
		end
		if type(data.version) ~= "string" or data.version == "" then
			return nil, "version must be a non-empty string"
		end
		if transition then
			for _, key in ipairs({ "build", "provides", "requires" }) do
				if data[key] ~= nil then return nil, "transition plugin has no " .. key end
			end
			if type(data.duration) ~= "number" or data.duration <= 0 or data.duration > 10000 or data.duration % 1 ~= 0 then
				return nil, "duration must be milliseconds in 1..10000"
			end
			local ink_at = data.ink_at == nil and 0.5 or data.ink_at
			if type(ink_at) ~= "number" or ink_at < 0 or ink_at > 1 then
				return nil, "ink_at must be in 0..1"
			end
			local easing = data.easing or { 0.25, 0.1, 0.25, 1 }
			if type(easing) ~= "table" or #easing ~= 4 then
				return nil, "easing must be four cubic-bezier numbers"
			end
			for _, value in ipairs(easing) do
				if type(value) ~= "number" then return nil, "easing must be four cubic-bezier numbers" end
			end
			if easing[1] < 0 or easing[1] > 1 or easing[3] < 0 or easing[3] > 1 then
				return nil, "easing x1 and x2 must be in 0..1"
			end
			return data
		end
		if type(data.build) ~= "string" or data.build == "" then
			return nil, "build must be a non-empty command string"
		end
		if type(data.provides) ~= "table" or #data.provides == 0 then
			return nil, "provides must be a non-empty array"
		end
		for _, item in ipairs(data.provides) do
			if type(item) ~= "string" or item == "" then
				return nil, "provides entries must be non-empty strings"
			end
			if item:sub(1, 1) == "/" or item:find("%.%.") then
				return nil, "provides entry escapes the build dir: " .. item
			end
		end
		if data.requires ~= nil then
			if type(data.requires) ~= "table" then
				return nil, "requires must be a table"
			end
			for key in pairs(data.requires) do
				if key ~= "hyprland" then
					return nil, "unknown requirement " .. key
				end
			end
			if data.requires.hyprland then
				local operator = constraint(data.requires.hyprland)
				if not operator then
					return nil, "bad requires.hyprland constraint " .. tostring(data.requires.hyprland)
				end
			end
		end
		return data
	end
	local function binary(path_)
		local name = path.filename(path_)
		local suffix = name:match("%.([^.]+)$")
		if suffix then
			suffix = "." .. suffix:lower()
			if suffix == ".so" or suffix == ".bin" or suffix == ".o" or suffix == ".a" or suffix == ".dylib" or suffix == ".dll" or suffix == ".exe" then
				return true
			end
		end
		local head = io.readfile(path_, { binary = true })
		return head ~= nil and head:sub(1, 4) == "\x7fELF"
	end
	local function source_only(plugin_dir)
		for _, file in ipairs(os.files(path.join(plugin_dir, "**"))) do
			if not path.relative(file, plugin_dir):find("^%.xmake/") and binary(file) then
				return "binary in plugin folder: " .. path.relative(file, plugin_dir)
			end
		end
		return nil
	end
	local function run_build(plugin_dir, data)
		local out = path.join(os.tmpdir(), "yudae-" .. path.filename(plugin_dir) .. "-" .. tostring(os.time()))
		os.tryrm(out)
		os.mkdir(out)
		local before = {}
		for _, file in ipairs(os.files(path.join(plugin_dir, "**"))) do
			before[path.relative(file, plugin_dir)] = true
		end
		local envs = os.getenvs()
		envs.OUT = out
		local command = string.format("cd '%s' && %s 2>&1; echo EXIT:$?", plugin_dir, data.build)
		local output = os.iorunv("sh", { "-c", command }, { envs = envs })
		local code = tonumber((output or ""):match("EXIT:(%d+)%s*$"))
		if code ~= 0 then
			local tail = {}
			for line in (output or ""):gmatch("([^\n]*)\n") do
				tail[#tail + 1] = line
			end
			local last = math.max(1, #tail - 11)
			return nil, "build failed:\n" .. table.concat(tail, "\n", last)
		end
		for _, item in ipairs(data.provides) do
			if not os.isfile(path.join(out, item)) then
				return nil, "build did not write " .. item
			end
		end
		for _, file in ipairs(os.files(path.join(plugin_dir, "**"))) do
			local rel = path.relative(file, plugin_dir)
			if not before[rel] and not rel:find("^%.xmake/") and not os.islink(file) then
				return nil, "build wrote into the plugin folder: " .. rel
			end
		end
		return out
	end
	local function check_theme(plugin_dir, data, out)
		local present = false
		for _, item in ipairs(data.provides) do
			if item == "theme.toml" then present = true end
		end
		if not present then
			return "theme plugin must provide theme.toml"
		end
		local body = io.readfile(path.join(out, "theme.toml"))
		if not body then
			return "build did not write theme.toml"
		end
		local theme, err = parse_toml(body)
		if not theme then
			return "bad theme.toml: " .. err
		end
		local allowed = color_keys(root)
		local sections = 0
		for section, entries in pairs(theme) do
			if type(entries) == "table" then
				local count = 0
				for name, value in pairs(entries) do
					count = count + 1
					if type(value) ~= "boolean" then
						if not allowed[name] then
							return string.format("theme color %s.%s is not a shell setting", section, name)
						end
						local hex = type(value) == "string" and value:match("^#(%x+)$")
						if not hex or (#hex ~= 6 and #hex ~= 8) then
							return string.format("theme color %s.%s is not #rrggbb or #aarrggbb", section, name)
						end
					end
				end
				if count > 0 then sections = sections + 1 end
			end
		end
		if sections == 0 then
			return "theme.toml needs at least one color table"
		end
		return nil
	end
	local function check_hypr(plugin_dir, data)
		if not os.isfile(path.join(plugin_dir, "hypr.lua")) then
			return "hypr plugin needs hypr.lua"
		end
		for _, item in ipairs(data.provides) do
			if item:sub(-3) == ".so" or item:sub(-4) == ".bin" then
				return nil
			end
		end
		return "hypr plugin must provide a .so or .bin"
	end
	local function check_shell(plugin_dir)
		local files = {}
		for _, file in ipairs(os.files(path.join(plugin_dir, "**"))) do
			if file:sub(-4) == ".qml" then
				files[#files + 1] = file
			end
		end
		if #files == 0 then
			return "shell plugin has no QML"
		end
		local lint = os.getenv("QMLLINT") or "/usr/lib/qt6/bin/qmllint"
		if not os.isfile(lint) then
			return "qmllint is missing"
		end
		local imports = path.join(os.tmpdir(), "yudae-qml-" .. tostring(os.time()))
		os.mkdir(imports)
		os.ln(path.join(root, "shell"), path.join(imports, "qs"))
		local quoted = {}
		for _, file in ipairs(files) do
			quoted[#quoted + 1] = "'" .. file .. "'"
		end
		local command = string.format("'%s' -I '%s' -I '%s' %s >/dev/null 2>&1; echo $?", lint, imports, plugin_dir, table.concat(quoted, " "))
		local code = tonumber(trim(os.iorunv("sh", { "-c", command }) or ""))
		os.rm(imports)
		if code ~= 0 then
			return code == 255 and "qmllint syntax error" or "qmllint failed"
		end
		return nil
	end
	local function check_transition(plugin_dir)
		local shader = path.join(plugin_dir, "transition.frag")
		if not os.isfile(shader) then
			return "transition plugin needs transition.frag"
		end
		local daemon = path.join(root, "daemon", "zig-out", "bin", "yudaemond")
		if not os.isfile(daemon) then
			return "build yudaemond first: it compiles the shader"
		end
		local output = os.iorunv("sh", { "-c", string.format("'%s' transition check '%s' 2>&1; echo EXIT:$?", daemon, shader) })
		if tonumber((output or ""):match("EXIT:(%d+)%s*$")) ~= 0 then
			return "shader does not compile:\n" .. trim((output or ""):gsub("EXIT:%d+%s*$", ""))
		end
		return nil
	end
	local function check(root_dir)
		if not os.isdir(root_dir) then
			return nil, "missing " .. root_dir
		end
		local count = 0
		for _, plugin_dir in ipairs(os.dirs(path.join(root_dir, "*"))) do
			if not path.filename(plugin_dir):match("^%.") then
				count = count + 1
				local name = path.filename(plugin_dir)
				local data, why = manifest(plugin_dir, name)
				if not data then
					return nil, string.format("%s: %s", name, why)
				end
				local have = hyprland_version()
				if data.requires and data.requires.hyprland then
					local operator, want = constraint(data.requires.hyprland)
					if have ~= "" and not satisfies(parse_version(have), operator, want) then
						return nil, string.format("%s: hyprland %s does not satisfy %s", name, have, data.requires.hyprland)
					end
				end
				local bad = source_only(plugin_dir)
				if bad then
					return nil, name .. ": " .. bad
				end
				if data.kind == "transition" then
					local why_transition = check_transition(plugin_dir)
					if why_transition then
						return nil, name .. ": " .. why_transition
					end
					print(string.format("ok %s (%s)", name, data.kind))
				elseif data.kind == "hypr" and have == "" then
					print(string.format("skip %s (hyprland missing)", name))
					print(string.format("ok %s (%s)", name, data.kind))
				else
					local out, build_why = run_build(plugin_dir, data)
					if not out then
						return nil, name .. ": " .. build_why
					end
					if data.kind == "theme" then
						bad = check_theme(plugin_dir, data, out)
					elseif data.kind == "hypr" then
						bad = check_hypr(plugin_dir, data)
					elseif data.kind == "shell" then
						bad = check_shell(plugin_dir)
					end
					os.rm(out)
					if bad then
						return nil, name .. ": " .. bad
					end
					print(string.format("ok %s (%s)", name, data.kind))
				end
			end
		end
		print(string.format("%s: %d checked", path.filename(root_dir), count))
		return true
	end
	for _, root_dir in ipairs({ path.join(root, "plugins"), path.join(root, "templates") }) do
		local ok, why = check(root_dir)
		if not ok then
			print("plugin check failed: " .. why)
			return false
		end
	end
	return true
end
