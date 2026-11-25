-- checks the wallpaper renderer on the live session: images, transitions, ink, video, pause,
-- still frames, audio, outputs and the VM share; puts the original wallpaper back at the end
import("core.base.json")
local util = import("util")
local trim = util.trim

local failures, passes = {}, 0

local function ok(name, detail)
	passes = passes + 1
	print(string.format("ok    %-22s %s", name, detail or ""))
end

local function fail(name, detail)
	failures[#failures + 1] = name
	print(string.format("FAIL  %-22s %s", name, detail or ""))
end

local function check(name, cond, detail)
	if cond then ok(name, detail) else fail(name, detail) end
	return cond
end

local function decode(text)
	return try { function () return json.decode(text) end, catch { function () end } }
end

local function sh(command)
	return trim(os.iorunv("sh", { "-c", command .. " 2>/dev/null; true" }) or "")
end

local function sh_all(command)
	return trim(os.iorunv("sh", { "-c", command .. " 2>&1; true" }) or "")
end

local function skip(name, detail)
	print(string.format("skip  %-22s %s", name, detail or ""))
end

local function call(target, method, args)
	local out = os.iorunv("yudae", { "--json", "call", target, method, json.encode(args or {}) }, { try = true }) or ""
	return decode(out)
end

local function cmd(target, method, args)
	os.execv("yudae", { "call", "-q", target, method, json.encode(args or {}) }, { try = true })
end

local function stats()
	return call("wallpaper", "stats", {}) or {}
end

local function state()
	return call("state", "x", {}) or {}
end

local function inks()
	local ink = state().ink or {}
	return ink.inks or {}
end

local function pid()
	return sh("pgrep -of 'yudaemond run'")
end

local function gpu_fds()
	local p = pid()
	if p == "" then return -1 end
	return tonumber(sh("ls -l /proc/" .. p .. "/fd | grep -c /dev/dri")) or -1
end

local function wait_for(seconds, test)
	local deadline = os.mclock() + seconds * 1000
	while os.mclock() < deadline do
		if test() then return true end
		os.sleep(200)
	end
	return test()
end

local function focused()
	local out = sh("hyprctl monitors -j")
	local monitors = decode(out)
	if monitors then
		for _, m in ipairs(monitors) do
			if m.focused then return m.name end
		end
		if monitors[1] then return monitors[1].name end
	end
	return ""
end

local function apply(path_, transition, output)
	cmd("wallpaper", "apply", { path = path_, transition = transition or "none", output = output })
end

local function fixtures(dir)
	os.mkdir(dir)
	local video = path.join(dir, "check-1080p30.mp4")
	if not os.isfile(video) then
		os.execv("ffmpeg", { "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30",
			"-f", "lavfi", "-i", "sine=frequency=440", "-t", "6", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", video })
	end
	local dark, light = path.join(dir, "check-dark.png"), path.join(dir, "check-light.png")
	if not os.isfile(dark) then
		os.execv("ffmpeg", { "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=0x101418:s=2560x1440", "-frames:v", "1", dark })
	end
	if not os.isfile(light) then
		os.execv("ffmpeg", { "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=0xeae6dc:s=2560x1440", "-frames:v", "1", light })
	end
	return { video = video, dark = dark, light = light }
end

local sections = {}

sections.daemon = function (ctx)
	local st = stats()
	check("daemon answers", st.running == true, "wallpaper.stats running=" .. tostring(st.running))
	local awww = sh("pgrep -x awww-daemon")
	if ctx.guest then
		skip("no awww", "guest; its desktop scripts come from the host repo")
	else
		check("no awww", awww == "", awww == "" and "awww-daemon is not running" or "awww-daemon still runs as pid " .. awww)
	end
	local shader = sh_all("yudae transition check '" .. path.join(ctx.root, "templates", "_template-transition", "transition.frag") .. "'")
	check("shader check", shader:find("^ok ") ~= nil, "template compiles on the real driver")
end

sections.images = function (ctx)
	local out = ctx.output
	for _, transition in ipairs({ "none", "fade", ctx.plugin }) do
		apply(ctx.f.dark, transition)
		local dark_ink = wait_for(4, function () return inks()[out] == "#ffffff" end)
		apply(ctx.f.light, transition)
		local light_ink = wait_for(4, function () return inks()[out] == "#000000" end)
		check("ink " .. transition, dark_ink and light_ink, "dark image gives white ink, light gives black on " .. out)
	end
	os.sleep(1000)
	local a = stats()
	os.sleep(3000)
	local b = stats()
	check("idle commits", (b.commits or 0) - (a.commits or 0) == 0, string.format("%d commits in 3s", (b.commits or 0) - (a.commits or 0)))
	check("idle gpu", b.gl == false and gpu_fds() == 0, string.format("gl=%s gpu fds=%d", tostring(b.gl), gpu_fds()))
	local share = path.join(os.getenv("XDG_RUNTIME_DIR") or "/run/user/1000", "yudae-state", "state.json")
	if ctx.guest then
		skip("vm share", "guest; only the host writes it")
	else
		wait_for(3, function () return os.isfile(share) end)
		local body = os.isfile(share) and io.readfile(share) or ""
		check("vm share", body:find(ctx.f.light, 1, true) ~= nil, share .. " names the shown image")
	end
end

sections.video = function (ctx)
	cmd("wallpaper", "frame", { path = ctx.f.video, t = 5.8 })
	apply(ctx.f.video, "fade")
	check("video plays", wait_for(5, function () return stats().video == "playing" end), "wallpaper.stats video=playing")
	os.sleep(500)
	local a = stats()
	os.sleep(3000)
	local b = stats()
	local rate = ((b.presented or 0) - (a.presented or 0)) / 3
	local decoded = ((b.decoded or 0) - (a.decoded or 0)) / 3
	check("video pacing", rate > 27 and rate < 33, string.format("%.1f presented/s, %.1f decoded/s for a 30 fps video", rate, decoded))
	check("video dropped", (b.dropped or 0) - (a.dropped or 0) == 0, string.format("%d dropped", (b.dropped or 0) - (a.dropped or 0)))
	check("video settles", wait_for(12, function () return stats().video == "still" end), "plays once and lands on the still frame")
	local c = stats()
	check("settle exact", (c.landedErrorMs or 99) < 34, string.format("landed %.2f ms from the still frame", c.landedErrorMs or -1))
	os.sleep(2000)
	local d = stats()
	os.sleep(3000)
	local e = stats()
	check("still idle", (e.commits or 0) - (d.commits or 0) == 0 and e.gl == false and gpu_fds() == 0, string.format("%d commits, gl=%s, gpu fds=%d", (e.commits or 0) - (d.commits or 0), tostring(e.gl), gpu_fds()))
	local share = path.join(os.getenv("XDG_RUNTIME_DIR") or "/run/user/1000", "yudae-state", "still.jpg")
	if ctx.guest then
		skip("vm share still", "guest; only the host writes it")
	else
		check("vm share still", wait_for(5, function () return os.isfile(share) end), share)
	end
end

sections.controls = function (ctx)
	apply(ctx.f.video, "none")
	wait_for(12, function () return stats().video == "still" end)
	cmd("wallpaper", "play", {})
	check("play", wait_for(3, function () return stats().video == "playing" end), "wallpaper.play ramps up from the still frame")
	os.sleep(1000)
	cmd("wallpaper", "pause", true)
	os.sleep(500)
	local a = stats()
	os.sleep(2000)
	local b = stats()
	check("pause", b.paused == true and b.commits == a.commits and b.decoded == a.decoded, string.format("paused at %.3fs, %d commits, %d decodes in 2s", b.position or -1, (b.commits or 0) - (a.commits or 0), (b.decoded or 0) - (a.decoded or 0)))
	cmd("wallpaper", "pause", false)
	os.sleep(500)
	local c = stats()
	check("resume", c.paused == false and (c.position or 0) >= (b.position or 0), string.format("resumed at %.3fs", c.position or -1))
	cmd("wallpaper", "settle", {})
	check("settle", wait_for(12, function () return stats().video == "still" end), "wallpaper.settle lands on the still frame")
end

sections.fullscreen = function (ctx)
	local term = os.getenv("TERMINAL") or "alacritty"
	apply(ctx.f.video, "none")
	wait_for(12, function () return stats().video == "still" end)
	cmd("wallpaper", "play", {})
	wait_for(3, function () return stats().video == "playing" end)
	local before = sh("hyprctl clients -j | grep -c '\"address\"'")
	sh(string.format("hyprctl eval 'hl.dispatch(hl.dsp.exec_cmd(\"%s\"))'", term))
	wait_for(5, function () return sh("hyprctl clients -j | grep -c '\"address\"'") ~= before end)
	os.sleep(800)
	sh("hyprctl eval 'hl.dispatch(hl.dsp.window.fullscreen())'")
	local paused = wait_for(3, function () return stats().paused == true end)
	check("fullscreen pauses", paused, "a fullscreen " .. term .. " pauses the video")
	sh("hyprctl eval 'hl.dispatch(hl.dsp.window.fullscreen())'")
	local resumed = wait_for(3, function () return stats().paused == false end)
	check("windowed resumes", resumed, "leaving fullscreen resumes it")
	sh("hyprctl eval 'hl.dispatch(hl.dsp.window.close())'")
	cmd("wallpaper", "settle", {})
	wait_for(12, function () return stats().video == "still" end)
end

sections.still = function (ctx)
	local strip = call("wallpaper", "filmstrip", { path = ctx.f.video })
	check("filmstrip", strip and strip.frames and #strip.frames > 0 and os.isfile(strip.frames[1].thumb), string.format("%d keyframe thumbnails", strip and strip.frames and #strip.frames or 0))
	local preview = call("wallpaper", "preview", { path = ctx.f.video, t = 2.5 })
	check("preview", preview and preview.thumb and os.isfile(preview.thumb), "exact frame at 2.5s")
	cmd("wallpaper", "frame", { path = ctx.f.video, t = 2.5 })
	os.sleep(500)
	local cache = io.readfile(path.join(os.getenv("HOME"), "dotfiles", "daemon", "cache", "wallpaper-videos.json")) or ""
	check("still saved", cache:find(ctx.f.video, 1, true) ~= nil and cache:find('"restFrame":2.5', 1, true) ~= nil, "restFrame 2.5 in daemon/cache/wallpaper-videos.json")
	local bench = sh_all("yudae bench wallpaper '" .. ctx.f.video .. "'")
	print(bench)
	if not ctx.guest then
		check("zero copy", bench:find("hw=yes zero_copy=yes", 1, true) ~= nil, "VA-API frames reach GL without a copy")
	else
		skip("zero copy", "guest without hardware video decode")
	end
	check("still pick", bench:find("still pick", 1, true) ~= nil, "the analyser picks a frame")
	check("audio", bench:match("audio %d+ frames in 1s, 0 after cork") ~= nil, "PipeWire stream plays and corks (inaudible volume)")
end

sections.outputs = function (ctx)
	apply(ctx.f.light, "none")
	wait_for(4, function () return inks()[ctx.output] == "#000000" end)
	sh("hyprctl output create headless WALLCHECK")
	local same = wait_for(6, function () return inks().WALLCHECK == "#000000" end)
	check("new output", same, "a hotplugged output gets the wallpaper and its own ink")
	apply(ctx.f.dark, "fade", "WALLCHECK")
	local split = wait_for(5, function () local i = inks() return i.WALLCHECK == "#ffffff" and i[ctx.output] == "#000000" end)
	check("per output ink", split, "different wallpapers keep separate inks")
	sh("hyprctl output remove WALLCHECK")
	check("output gone", wait_for(4, function () return inks().WALLCHECK == nil end), "a removed output drops its ink")
end

local order = { "daemon", "images", "video", "controls", "fullscreen", "still", "outputs" }

function run(root, wanted)
	local dir = path.join(os.getenv("XDG_CACHE_HOME") or path.join(os.getenv("HOME"), ".cache"), "yudae", "wallpaper-check")
	local before = state()
	local original = before.wallpaper and before.wallpaper.active or ""
	local data = path.join(os.getenv("XDG_DATA_HOME") or path.join(os.getenv("HOME"), ".local", "share"), "yudae", "plugins", "wallcheck-wipe")
	os.mkdir(data)
	io.writefile(path.join(data, "plugin.toml"), ((io.readfile(path.join(root, "templates", "_template-transition", "plugin.toml")) or ""):gsub("_template%-transition", "wallcheck-wipe")))
	os.cp(path.join(root, "templates", "_template-transition", "transition.frag"), path.join(data, "transition.frag"))
	local ctx = { root = root, f = fixtures(dir), output = focused(), plugin = "wallcheck-wipe", guest = stats().guest == true }
	print("output " .. ctx.output .. ", fixtures in " .. dir .. ", original wallpaper " .. original)
	local list = (wanted and wanted ~= "" and wanted ~= "all") and { wanted } or order
	for _, name in ipairs(list) do
		local section = sections[name]
		if not section then raise("unknown section " .. name .. "; one of: all " .. table.concat(order, " ")) end
		print("== " .. name)
		try { function () section(ctx) end, catch { function (err) fail(name, tostring(err)) end } }
	end
	cmd("wallpaper", "pause", false)
	if original ~= "" then apply(original, "fade") end
	os.rm(data)
	print(string.format("%d passed, %d failed", passes, #failures))
	if #failures > 0 then raise("wallpaper check failed: " .. table.concat(failures, ", ")) end
end
