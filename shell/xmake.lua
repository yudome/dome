-- shell checks and native plugin

local dir = os.scriptdir()
local root = path.directory(dir)

target("shell-checks")
	set_kind("phony")
	set_default(false)
	add_tests("static")
	on_test(function ()
		local failures = {}

		local function relative(file)
			return path.relative(file, root)
		end

		local function each_line(file, visit)
			local body = io.readfile(file) or ""
			local number = 0
			for line in (body .. "\n"):gmatch("([^\n]*)\n") do
				number = number + 1
				visit(line, number)
			end
		end

		-- colors come from Config.qml
		local config = path.join(root, "shell", "services", "Config.qml")
		local color_keys = { color = true, barColor = true, textColor = true, fillColor = true }
		for _, file in ipairs(os.files(path.join(root, "shell", "**", "*.qml"))) do
			if file ~= config and not file:find("/cache/", 1, true) then
				each_line(file, function (line, number)
					local key, value = line:match("([%a_][%w_]*)%s*:%s*\"([^\"]*)\"")
					if key and color_keys[key] then
						local hex = value:match("^#(%x+)$")
						if (hex and #hex >= 3 and #hex <= 8) or value == "white" or value == "black" or value == "gray" or value == "grey" then
							failures[#failures + 1] = string.format("%s:%d: %s", relative(file), number, line)
						end
					end
				end)
			end
		end

		-- kit layers
		local kits = { ui = true, appkit = true, panelkit = true }
		local scroll_owners = { ui = true, appkit = true }
		local retired = { "GlyphBar", "GlyphRow", "BarIcon", "RevealIcon", "AppIcon", "ArrowPill" }
		local data_visuals = { ["AgentFace.qml"] = true, ["Bubbles.qml"] = true, ["Stage.qml"] = true, ["Session.qml"] = true }
		local hint_words = { "to type", "to try", "to refresh", "to fetch", "to copy", "to build", "press", "click", "tap", "hit enter" }
		local modifiers = { "Alt", "Ctrl", "Super", "Shift" }

		local tokens = {}
		for line in (io.readfile(config) or ""):gmatch("[^\n]+") do
			local name = line:match("^%s*property%s+[%w_%.]+%s+([%w_]+)") or line:match("^%s*readonly%s+property%s+[%w_%.]+%s+([%w_]+)") or line:match("^%s*function%s+([%w_]+)")
			if name then
				tokens[name] = true
			end
		end

		local function block_set(lines, name)
			local found = {}
			local index = 0
			while index < #lines do
				local opened = lines[index + 1]:match("^(%s*)" .. name .. " {$") or lines[index + 1]:match("^(%s*)%w+: " .. name .. " {$")
				if opened then
					local last = index + 1
					while last < #lines and lines[last + 1] ~= opened .. "}" do
						last = last + 1
					end
					for current = index, last do
						found[current] = true
					end
					index = last + 1
				else
					index = index + 1
				end
			end
			return found
		end

		local function text_blocks(lines, name)
			local found = {}
			local index = 0
			while index < #lines do
				local opened = lines[index + 1]:match("^(%s*)" .. name .. " {$") or lines[index + 1]:match("^(%s*)delegate: " .. name .. " {$")
				if opened then
					local inner = opened .. "\t"
					local last = index + 1
					while last < #lines and lines[last + 1] ~= opened .. "}" do
						last = last + 1
					end
					local direct = {}
					for current = index + 1, last - 1 do
						local prop = lines[current + 1]
						if prop:sub(1, #inner) == inner and prop:sub(1, #inner + 1) ~= inner .. "\t" then
							direct[#direct + 1] = prop:gsub("^%s+", ""):gsub("%s+$", "")
						end
					end
					found[#found + 1] = { number = index + 1, direct = direct }
					index = last + 1
				else
					index = index + 1
				end
			end
			return found
		end

		local function hint_text(code)
			local lower = code:lower()
			for _, word in ipairs(hint_words) do
				if lower:match('"[^"]*%f[%w]' .. word .. '%f[%W][^"]*"') then
					return true
				end
			end
			for _, modifier in ipairs(modifiers) do
				if code:match('"' .. modifier .. '%s*"%s*%+') then
					return true
				end
			end
			return false
		end

		local function glyph_text(prop)
			if prop:match("^text:%s*Config%.icon%w+") or prop:match("^text:%s*Config%.glyph%(") then
				return true
			end
			local name = prop:match("^text:%s*Config%.(%w+)")
			return name ~= nil and name:match("^%w+Icon%w*$") ~= nil
		end

		for _, file in ipairs(os.files(path.join(root, "shell", "**", "*.qml"))) do
			if not file:find("/cache/", 1, true) then
				local body = io.readfile(file) or ""
				local lines = {}
				for line in (body .. "\n"):gmatch("([^\n]*)\n") do
					lines[#lines + 1] = line
				end
				table.remove(lines)

				local hints = block_set(lines, "Hint")
				local where = path.relative(file, dir):match("^([^/]+)/") or ""
				local rel = relative(file)

				local function fail(number, message)
					failures[#failures + 1] = string.format("%s:%d: %s", rel, number, message)
				end

				for index, line in ipairs(lines) do
					local code = line:gsub("//.*$", "")
					if code:match("%f[%w]Scrollbar%s*{") and not scroll_owners[where] then
						fail(index, "Scrollbar outside ui and appkit; use AppScroll")
					end
					if code:find("Behavior on contentY", 1, true) then
						fail(index, "Behavior on contentY; scrolling is never smoothed")
					end
					for _, name in ipairs(retired) do
						if code:match("%f[%w]" .. name .. "%s*{") then
							fail(index, name .. " is retired")
						end
					end
					if file ~= config and code:match("%f[%w]font%.pixelSize%s*:%s*%d") then
						fail(index, "font size literal; use a Config token or a Label role")
					end
					if file ~= config and code:match("%f[%w](radius|duration)%s*:%s*[1-9]") then
						fail(index, "radius or duration literal; use a Config token")
					end
					for name in code:gmatch("Config%.([%w_]+)") do
						if not tokens[name] then
							fail(index, "Config." .. name .. " does not exist")
						end
					end
					if file ~= config and path.filename(file) ~= "Hint.qml" and not hints[index - 1] and hint_text(code) then
						fail(index, "hint text outside Hint; draw hints through ui/Hint.qml")
					end
					if line:find("·", 1, true) then
						fail(index, "dot separator; separate with spacing")
					end
					if kits[where] and code:match("%f[%w]Yudae%f[%W]") then
						fail(index, where .. " talks to the daemon; move it into a feature Store")
					end
					if kits[where] and (code:match("import%s+qs%.features") or code:match('import%s+"%.%./features') or code:match('import%s+"%.%./%.%./features')) then
						fail(index, where .. " imports a feature")
					end
					if where == "ui" then
						local kit = code:match("import%s+qs%.(%w+)")
						if kit == "appkit" or kit == "panelkit" then
							fail(index, "ui imports a kit")
						end
					end
				end

				if not kits[where] and not data_visuals[path.filename(file)] then
					for _, block in ipairs(text_blocks(lines, "Text")) do
						for _, prop in ipairs(block.direct) do
							if prop:match("^font%.pixelSize:%s*(Settings%.fontSize|Config%.fontSize)%s*$") or prop:sub(1, 11) == "font.family" then
								fail(block.number, "raw Text; use Label")
							end
							if glyph_text(prop) then
								fail(block.number, "glyph drawn as Text; use Icon")
							end
						end
					end
					for _, block in ipairs(text_blocks(lines, "Label")) do
						for _, prop in ipairs(block.direct) do
							if glyph_text(prop) then
								fail(block.number, "glyph drawn as Label; use Icon or IconButton")
							end
						end
					end
				end
			end
		end

		local qmldir = path.join(root, "shell", "ui", "qmldir")
		local qmldir_body = io.readfile(qmldir) or ""
		for _, name in ipairs(retired) do
			if qmldir_body:match("^" .. name .. " ") then
				failures[#failures + 1] = relative(qmldir) .. ": " .. name .. " is retired"
			end
		end

		-- Slider.qml logic, mirrored in Lua
		local function new_slider(props)
			local self = { from = 0, to = 1, stepSize = 0, stops = {}, held = -1, value = 0 }
			for key, value in pairs(props or {}) do
				self[key] = value
			end
			self.stopCount = #self.stops
			return self
		end

		local function stopValue(self, entry)
			return type(entry) == "table" and entry.value or entry
		end

		local function num(v)
			return tonumber(v) or (0 / 0)
		end

		local function nearestStop(self, v)
			local best = 1
			for index = 1, self.stopCount do
				if stopValue(self, self.stops[index]) == v then
					return index
				end
				if math.abs(num(stopValue(self, self.stops[index])) - num(v)) < math.abs(num(stopValue(self, self.stops[best])) - num(v)) then
					best = index
				end
			end
			return best
		end

		local function indexAt(self, n)
			return self.stopCount > 1 and math.floor(n * (self.stopCount - 1) + 0.5) or 0
		end

		local function normalize(self, v)
			if self.stopCount > 0 then
				return self.stopCount > 1 and (nearestStop(self, v) - 1) / (self.stopCount - 1) or 0
			end
			if self.to > self.from then
				return math.min(math.max((tonumber(v) - self.from) / (self.to - self.from), 0), 1)
			end
			return 0
		end

		local function snap(self, n)
			if self.stopCount > 1 then
				return indexAt(self, n) / (self.stopCount - 1)
			end
			if self.stepSize > 0 and self.to > self.from then
				local steps = (self.to - self.from) / self.stepSize
				return math.floor(n * steps + 0.5) / steps
			end
			return n
		end

		local function valueAt(self, n)
			if self.stopCount > 0 then
				return stopValue(self, self.stops[indexAt(self, n) + 1])
			end
			local v = self.from + n * (self.to - self.from)
			if self.stepSize > 0 then
				return tonumber(string.format("%.6f", math.floor(v / self.stepSize + 0.5) * self.stepSize))
			end
			return v
		end

		local function unit(self)
			if self.stopCount > 1 then
				return 1 / (self.stopCount - 1)
			end
			if self.stepSize > 0 and self.to > self.from then
				return self.stepSize / (self.to - self.from)
			end
			return 0.01
		end

		local function close(a, b)
			if type(a) == "number" and type(b) == "number" then
				return math.abs(a - b) < 1e-9
			end
			return a == b
		end

		local function expect(got, want, why)
			if not close(got, want) then
				failures[#failures + 1] = string.format("slider %s: got %s, want %s", why, tostring(got), tostring(want))
			end
		end

		local stops = new_slider({ stops = { { label = "60", value = 60 }, { label = "120", value = 120 }, { label = "144", value = 144 } } })
		expect(normalize(stops, 120), 0.5, "normalize(120)")
		expect(normalize(stops, 130), 0.5, "normalize(130)")
		expect(valueAt(stops, snap(stops, 0.8)), 144, "valueAt(snap(0.8))")
		expect(valueAt(stops, 0), 60, "valueAt(0)")
		expect(unit(stops), 0.5, "unit()")

		local text = new_slider({ stops = { "powersave", "balanced", "performance" } })
		expect(normalize(text, "performance"), 1, "normalize(performance)")
		expect(valueAt(text, snap(text, 0.4)), "balanced", "valueAt(snap(0.4))")

		local range = new_slider({ from = 1, to = 2, stepSize = 0.25 })
		expect(normalize(range, 1.5), 0.5, "range normalize(1.5)")
		expect(valueAt(range, snap(range, 0.6)), 1.5, "range valueAt(snap(0.6))")
		expect(normalize(range, 9), 1, "range normalize(9)")
		expect(unit(range), 0.25, "range unit()")

		local free = new_slider({ from = 0, to = 10 })
		expect(valueAt(free, 0.37), 3.7, "free valueAt(0.37)")

		if #failures > 0 then
			for _, failure in ipairs(failures) do
				print(failure)
			end
			print(string.format("shell rules broken: %d", #failures))
			return false
		end
		print("colors, kit layers and slider mapping hold")
		return true
	end)

target("shell-app")
	set_kind("phony")
	set_default(false)
	add_tests("app")
	on_test(function ()
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
	end)

target("shell-lint")
	set_kind("phony")
	set_default(false)
	add_tests("qml")
	on_test(function ()
		local imports = path.join(os.tmpdir(), "qmlimport")
		os.tryrm(imports)
		os.mkdir(imports)
		os.ln(dir, path.join(imports, "qs"))

		local fail = 0
		local lint = "/usr/lib/qt6/bin/qmllint"
		if not os.isfile(lint) then
			print("qmllint missing, skipping")
			return true
		end
		for _, file in ipairs(os.files(path.join(dir, "**", "*.qml"))) do
			if not file:find("/cache/", 1, true) then
				local command = string.format("'%s' -I '%s' '%s' >/dev/null 2>&1; echo $?", lint, imports, file)
				local out = os.iorunv("sh", { "-c", command })
				if out:trim() ~= "0" then
					print("qmllint failed: " .. file)
					fail = fail + 1
				end
			end
		end
		if fail > 0 then
			print(string.format("qmllint failed: %d", fail))
			return false
		end
		print("qmllint clean")
		return true
	end)

target("shell-face")
	set_kind("phony")
	set_default(false)
	add_tests("face")
	on_test(function ()
		local twoPi = math.pi * 2

		local function round(x) return math.floor(x + 0.5) end

		local function clamp01(x) return math.max(0, math.min(1, x)) end

		local function superellipseRadius(angle, exponent)
			local cos = math.abs(math.cos(angle))
			local sin = math.abs(math.sin(angle))
			return (cos ^ exponent + sin ^ exponent) ^ (-1 / exponent)
		end

		local function shapePoints(spec)
			local width = math.max(1, spec.width or 1)
			local height = math.max(1, spec.height or 1)
			local exponent = spec.exponent or 2
			local lobes = math.max(0.5, spec.lobes or 1)
			local scallop = math.min(0.9, math.max(0, spec.scallop == nil and 0 or spec.scallop))
			local depth = math.min(0.9, scallop * (spec.morph == nil and 1 or spec.morph))
			local samples = math.max(24, round(spec.samples or 128))
			local cx, cy = width / 2, height / 2
			local points = {}

			for i = 0, samples - 1 do
				local fraction = i / samples
				local angle = fraction * twoPi - math.pi / 2
				local radius = superellipseRadius(angle, exponent)
				local phase = math.fmod(fraction * lobes + 0.5, 1)
				local wave = 1 - depth * (0.5 - 0.5 * math.cos(twoPi * phase))
				points[#points + 1] = cx + radius * math.cos(angle) * cx * wave
				points[#points + 1] = cy + radius * math.sin(angle) * cy * wave
			end
			return points
		end

		local function blendPoints(from, to, progress)
			local amount = clamp01(progress)
			local points = {}
			for i = 1, #from do
				points[i] = from[i] + (to[i] - from[i]) * amount
			end
			return points
		end

		local function rotatePoints(points, cx, cy, angle)
			if angle == 0 then return points end
			local cos, sin = math.cos(angle), math.sin(angle)
			local out = {}
			for i = 1, #points, 2 do
				local x, y = points[i] - cx, points[i + 1] - cy
				out[i] = cx + x * cos - y * sin
				out[i + 1] = cy + x * sin + y * cos
			end
			return out
		end

		local function ellipsePoints(cx, cy, radiusX, radiusY, samples)
			local count = math.max(12, round(samples or 24))
			local points = {}
			for i = 0, count - 1 do
				local angle = (i / count) * twoPi
				points[#points + 1] = cx + math.cos(angle) * radiusX
				points[#points + 1] = cy + math.sin(angle) * radiusY
			end
			return points
		end

		local function roundedRectPoints(cx, cy, halfWidth, halfHeight, radius, samples)
			local count = math.max(2, round((samples or 40) / 4))
			local r = math.min(radius, math.min(halfWidth, halfHeight))
			local points = {}
			local corners = {
				{ cx + halfWidth - r, cy - halfHeight + r, -math.pi / 2 },
				{ cx + halfWidth - r, cy + halfHeight - r, 0 },
				{ cx - halfWidth + r, cy + halfHeight - r, math.pi / 2 },
				{ cx - halfWidth + r, cy - halfHeight + r, math.pi },
			}
			for i = #corners, 1, -1 do
				local corner = corners[i]
				for j = count, 0, -1 do
					local angle = corner[3] + (j / count) * (math.pi / 2)
					points[#points + 1] = corner[1] + math.cos(angle) * r
					points[#points + 1] = corner[2] + math.sin(angle) * r
				end
			end
			return points
		end

		local function socketInside(outline, cx, cy, radiusX, radiusY, samples, margin)
			local total = #outline / 2
			local stride = math.max(1, math.floor(total / 48))
			local count = math.floor(total / stride)
			local gap = margin or 0
			local edge = roundedRectPoints(cx, cy, radiusX + gap, radiusY + gap, math.min(radiusX, radiusY) + gap, samples or 24)

			for i = 1, #edge, 2 do
				local x, y = edge[i], edge[i + 1]
				local insidePoint = false
				for j = 0, count - 1 do
					local k = (j == 0) and count - 1 or j - 1
					local xi = outline[2 * j * stride + 1]
					local yi = outline[2 * j * stride + 2]
					local xk = outline[2 * k * stride + 1]
					local yk = outline[2 * k * stride + 2]
					if ((yi > y) ~= (yk > y)) and x < (xk - xi) * (y - yi) / (yk - yi) + xi then
						insidePoint = not insidePoint
					end
				end
				if not insidePoint then return false end
			end
			return true
		end

		local function clipSockets(outline, sockets, margin)
			local function inside(socket, factor)
				return socketInside(outline, socket.x, socket.y, socket.radiusX * factor, socket.radiusY * factor, 24, margin or 0)
			end
			local low, high = 0, 1
			for _ = 1, 12 do
				local mid = (low + high) / 2
				local ok = true
				for _, socket in ipairs(sockets) do
					if not inside(socket, mid) then ok = false break end
				end
				if ok then low = mid else high = mid end
			end
			local fitted = {}
			for i, socket in ipairs(sockets) do
				fitted[i] = { x = socket.x, y = socket.y, radiusX = socket.radiusX * low, radiusY = socket.radiusY * low }
			end
			return fitted
		end

		local function clampShift(outline, sockets, dx, dy, margin)
			local function fits(t)
				for _, socket in ipairs(sockets) do
					if not socketInside(outline, socket.x + dx * t, socket.y + dy * t, socket.radiusX, socket.radiusY, 8, margin or 0) then
						return false
					end
				end
				return true
			end
			local low, high = 0, 1
			for _ = 1, 8 do
				local mid = (low + high) / 2
				if fits(mid) then low = mid else high = mid end
			end
			return { x = dx * low, y = dy * low }
		end

		local function circleInside(points, cx, cy)
			local radius = math.huge
			for i = 1, #points, 2 do
				radius = math.min(radius, math.sqrt((points[i] - cx) ^ 2 + (points[i + 1] - cy) ^ 2))
			end
			return ellipsePoints(cx, cy, radius, radius, 48)
		end

		local function maxReach(outline, sockets, travel, margin)
			local reaches = {}
			for i = 0, 15 do
				local angle = i / 16 * twoPi
				local shift = clampShift(outline, sockets, math.cos(angle) * travel, math.sin(angle) * travel, margin)
				reaches[i + 1] = math.sqrt(shift.x ^ 2 + shift.y ^ 2)
			end
			local out = {}
			for i = 1, 16 do
				local next = reaches[(i % 16) + 1]
				local previous = reaches[((i - 2) % 16) + 1]
				out[i] = math.min(reaches[i], next, previous)
			end
			return out
		end

		local function reachAt(reaches, angle)
			local count = #reaches
			local at = math.fmod(angle / twoPi * count, count)
			if at < 0 then at = at + count end
			local low = math.floor(at)
			local blend = at - low
			return reaches[low + 1] * (1 - blend) + reaches[(low + 1) % count + 1] * blend
		end

		local size = 44
		local width = size * 0.86
		local height = size * 0.86
		local margin = size * 0.02

		local sockets = {
			{ x = width / 2 - size * 0.22, y = height / 2 - size * 0.04, radiusX = size * 0.105, radiusY = size * 0.185 },
			{ x = width / 2 + size * 0.22, y = height / 2 - size * 0.04, radiusX = size * 0.105, radiusY = size * 0.185 },
		}

		local shapes = {
			idle = { exponent = 2, lobes = 1, scallop = 0 },
			working = { exponent = 2, lobes = 9, scallop = 0.16 },
			blocked = { exponent = 2, lobes = 3, scallop = 0.28 },
			error = { exponent = 1, lobes = 1, scallop = 0 },
		}
		local names = { "idle", "working", "blocked", "error" }

		local function bodyAt(samples, from, to, morph)
			local spec = { width = width, height = height, samples = samples }
			local a, b = {}, {}
			for key, value in pairs(shapes[from]) do a[key] = value end
			for key, value in pairs(shapes[to]) do b[key] = value end
			for key, value in pairs(spec) do a[key] = value b[key] = value end
			return blendPoints(shapePoints(a), shapePoints(b), morph)
		end

		local function socketInsideWhole(outline, cx, cy, radiusX, radiusY, samples, gap)
			local count = #outline / 2
			local edge = roundedRectPoints(cx, cy, radiusX + gap, radiusY + gap, math.min(radiusX, radiusY) + gap, samples)
			for i = 1, #edge, 2 do
				local inside = false
				for j = 0, count - 1 do
					local k = (j == 0) and count - 1 or j - 1
					local xi, yi = outline[2 * j + 1], outline[2 * j + 2]
					local xk, yk = outline[2 * k + 1], outline[2 * k + 2]
					if ((yi > edge[i + 1]) ~= (yk > edge[i + 1])) and edge[i] < (xk - xi) * (edge[i + 1] - yi) / (yk - yi) + xi then
						inside = not inside
					end
				end
				if not inside then return false end
			end
			return true
		end

		local function fitWhole(outline)
			local low, high = 0, 1
			for _ = 1, 12 do
				local mid = (low + high) / 2
				local ok = true
				for _, socket in ipairs(sockets) do
					if not socketInsideWhole(outline, socket.x, socket.y, socket.radiusX * mid, socket.radiusY * mid, 24, margin) then
						ok = false
						break
					end
				end
				if ok then low = mid else high = mid end
			end
			return low
		end

		local failures = {}
		local worst = 0
		local function check(condition, message)
			if not condition then
				failures[#failures + 1] = message
				return false
			end
			return true
		end

		for _, samples in ipairs({ 48, 96, 160, 320 }) do
			for _, from in ipairs(names) do
				for _, to in ipairs(names) do
					for step = 0, 20 do
						local morph = step / 20
						local body = bodyAt(samples, from, to, morph)
						local fitted = clipSockets(body, sockets, margin)
						local reference = fitWhole(body)
						local where = string.format("%s->%s samples=%d morph=%.2f", from, to, samples, morph)
						for i = 1, #fitted do
							local socket = fitted[i]
							if not check(socket.radiusX > 0 and socket.radiusY > 0, "eye vanished at " .. where) then break end
							if not check(socketInsideWhole(body, socket.x, socket.y, socket.radiusX, socket.radiusY, 24, margin - 0.05), "eye lost its margin at " .. where) then break end
							local drift = math.max(math.abs(socket.radiusX - sockets[i].radiusX * reference), math.abs(socket.radiusY - sockets[i].radiusY * reference))
							worst = math.max(worst, drift)
							if not check(drift < 0.15, string.format("eye drifted %.3fpx from the full-outline fit at %s", drift, where)) then break end
						end
						if #failures > 0 then break end
					end
					if #failures > 0 then break end
				end
				if #failures > 0 then break end
			end
			if #failures > 0 then break end
		end

		local function area(points)
			local sum = 0
			local len = #points
			local function at(index)
				return points[(index - 1) % len + 1]
			end
			for i = 1, len, 2 do
				sum = sum + points[i] * at(i + 3) - at(i + 2) * points[i + 1]
			end
			return sum
		end

		for _, name in ipairs(names) do
			check(area(bodyAt(48, name, name, 1)) * area(roundedRectPoints(10, 10, 3, 6, 3, 40)) < 0, "eye winds with the " .. name .. " body")
		end

		for _, name in ipairs(names) do
			local body = bodyAt(160, name, name, 1)
			local fitted = clipSockets(body, sockets, margin)
			local reaches = maxReach(body, fitted, size * 0.055, margin)
			local top = 0
			for _, reach in ipairs(reaches) do top = math.max(top, reach) end
			check(top > 0, "eyes cannot move in the " .. name .. " body")
			for i = 0, 63 do
				local angle = i / 64 * twoPi
				local reach = reachAt(reaches, angle)
				for _, socket in ipairs(fitted) do
					check(socketInsideWhole(body, socket.x + math.cos(angle) * reach, socket.y + math.sin(angle) * reach, socket.radiusX, socket.radiusY, 24, 0), string.format("eye leaves the %s body looking at %d degrees", name, math.floor(angle * 180 / math.pi + 0.5)))
				end
			end
		end

		local body = bodyAt(160, "working", "working", 1)
		local safe = circleInside(body, width / 2, height / 2)
		local fitted = clipSockets(safe, sockets, margin)
		local reaches = maxReach(safe, fitted, size * 0.055, margin)
		for turn = 0, 38, 2 do
			local turned = rotatePoints(body, width / 2, height / 2, turn * math.pi / 180)
			for i = 0, 63 do
				local angle = i / 64 * twoPi
				local reach = reachAt(reaches, angle)
				for _, socket in ipairs(fitted) do
					check(socketInsideWhole(turned, socket.x + math.cos(angle) * reach, socket.y + math.sin(angle) * reach, socket.radiusX, socket.radiusY, 24, 0), string.format("eye crosses the spinning body at %d degrees", turn))
				end
			end
		end

		if #failures > 0 then
			for index = 1, math.min(8, #failures) do
				print(failures[index])
			end
			return false
		end
		print(string.format("AgentFace: eye fit holds, worst drift %.4fpx", worst))
		return true
	end)

includes("native")

task("link")
	set_category("action")
	set_menu {
		usage = "xmake link",
		description = "link the config, hypr, systemd units and icons into $HOME",
	}
	on_run(function ()
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
	end)

task("lint")
	set_category("action")
	set_menu {
		usage = "xmake lint",
		description = "qmllint, color, kit, app and face checks",
	}
	on_run(function ()
		for _, test in ipairs({ "shell-lint/qml", "shell-checks/static", "shell-face/face" }) do
			os.execv("xmake", { "test", test }, { curdir = root })
		end
		print("lint clean")
	end)

target("greeter")
	set_kind("phony")
	set_default(false)
	after_install(function ()
		local function trim(text)
			return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
		end
		local uid = trim(os.iorunv("id", { "-u" }))
		if uid ~= "0" then
			raise("run as root: sudo xmake install greeter")
		end
		local target = trim(os.iorunv("sh", { "-c", "getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }'" }))
		if target == "" then
			raise("no login user found")
		end
		local home = trim(os.iorunv("sh", { "-c", "getent passwd '" .. target .. "' | cut -d: -f6" }))
		local repo = path.join(home, "dotfiles")
		local start = path.join(repo, "shell", "features", "greeter", "start")

		for _, tool in ipairs({ "cage", "quickshell" }) do
			if os.execv("sh", { "-c", "command -v " .. tool }, { try = true }) ~= 0 then
				raise("missing " .. tool)
			end
		end
		os.execv("chmod", { "o+x", home })
		if os.execv("runuser", { "-u", "greeter", "--", "test", "-x", start }, { try = true }) ~= 0
			or os.execv("runuser", { "-u", "greeter", "--", "test", "-r", path.join(repo, "shell", "greeterShell.qml") }, { try = true }) ~= 0 then
			raise("greeter cannot run " .. start)
		end

		os.execv("rm", { "-rf", "/etc/greetd/quickshell", "/var/lib/quickshell/greeter" })
		os.execv("rmdir", { "/var/lib/quickshell" }, { try = true })
		os.execv("rm", { "-f", "/etc/greetd/hyprland.lua", "/etc/greetd/start-greeter",
			"/etc/sudoers.d/greeter-power", "/etc/sudoers.d/greeter-logout", "/usr/local/bin/qs-logout",
			"/etc/tmpfiles.d/greetd-greeter.conf" })
		os.execv("usermod", { "-aG", "video,render,input", "greeter" })
		os.execv("install", { "-d", "-m", "700", "-o", "greeter", "-g", "greeter", "/var/lib/greetd" })

		os.execv("install", { "-d", "-m", "755", "/etc/polkit-1/rules.d" })
		io.writefile("/etc/polkit-1/rules.d/49-quickshell-greeter.rules", string.format([[
polkit.addRule(function (action, subject) {
	if (action.id == "org.freedesktop.systemd1.manage-units" &&
		subject.user == "%s" &&
		action.lookup("unit") == "greetd.service" &&
		action.lookup("verb") == "start") {
		return polkit.Result.YES;
	}

	if (subject.user == "greeter" &&
		(action.id == "org.freedesktop.login1.power-off" ||
		 action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
		 action.id == "org.freedesktop.login1.reboot" ||
		 action.id == "org.freedesktop.login1.reboot-multiple-sessions")) {
		return polkit.Result.YES;
	}
});
]], target))
		os.execv("chmod", { "644", "/etc/polkit-1/rules.d/49-quickshell-greeter.rules" })

		if not os.exists("/etc/security/faillock.conf.bak") then
			os.execv("cp", { "-a", "/etc/security/faillock.conf", "/etc/security/faillock.conf.bak" })
		end
		io.writefile("/etc/security/faillock.conf", "deny = 3\nunlock_time = 3\n")

		os.execv("install", { "-d", "-m", "755", "/etc/greetd" })
		if not os.exists("/etc/greetd/config.toml.bak") then
			os.execv("cp", { "-a", "/etc/greetd/config.toml", "/etc/greetd/config.toml.bak" })
		end
		io.writefile("/etc/sysctl.d/60-greeter-quiet.conf", "kernel.printk = 1 4 1 7\n")
		os.execv("sysctl", { "-q", "-p", "/etc/sysctl.d/60-greeter-quiet.conf" }, { try = true })
		io.writefile("/etc/greetd/config.toml", string.format([[
[terminal]
vt = 1
switch = false

[default_session]
command = "%s %s"
user = "greeter"
]], start, target))

		os.execv("faillock", { "--user", target, "--reset" }, { try = true, stdout = "/dev/null", stderr = "/dev/null" })
		os.execv("systemctl", { "disable", "sddm" }, { try = true, stdout = "/dev/null", stderr = "/dev/null" })
		os.execv("systemctl", { "enable", "greetd" }, { try = true, stdout = "/dev/null" })

		print("greeter installed for " .. target)
		print("your current session is untouched; reboot to test.")
		print("rollback: sudo xmake uninstall greeter")
	end)
	after_uninstall(function ()
		local function trim(text)
			return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
		end
		local uid = trim(os.iorunv("id", { "-u" }))
		if uid ~= "0" then
			raise("run as root: sudo xmake uninstall greeter")
		end
		os.execv("systemctl", { "disable", "greetd" }, { try = true, stdout = "/dev/null", stderr = "/dev/null" })
		os.execv("systemctl", { "enable", "sddm" }, { try = true, stdout = "/dev/null", stderr = "/dev/null" })
		if os.execv("sh", { "-c", "command -v sddm" }, { try = true }) ~= 0 then
			print("sddm is not installed; reinstall it with: sudo pacman -S sddm")
		end
		if os.exists("/etc/greetd/config.toml.bak") then
			os.execv("cp", { "-a", "/etc/greetd/config.toml.bak", "/etc/greetd/config.toml" })
		end
		if os.exists("/etc/security/faillock.conf.bak") then
			os.execv("cp", { "-a", "/etc/security/faillock.conf.bak", "/etc/security/faillock.conf" })
		end
		os.execv("rm", { "-f", "/etc/polkit-1/rules.d/49-quickshell-greeter.rules", "/etc/sysctl.d/60-greeter-quiet.conf" })
		os.execv("sysctl", { "-q", "--system" }, { try = true, stdout = "/dev/null", stderr = "/dev/null" })
		print("greetd disabled, sddm enabled. reboot to return to sddm.")
	end)
