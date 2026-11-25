function run(root, dir)
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
end
