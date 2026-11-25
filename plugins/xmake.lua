-- plugin manifests, source-only rule and the plugin build task

local dir = os.scriptdir()
local root = path.directory(dir)

task("plugin")
	set_category("action")
	set_menu {
		usage = "xmake plugin",
		description = "build every plugin, hypr included",
	}
	on_run(function ()
		local state = path.join(os.getenv("XDG_STATE_HOME") or path.join(os.getenv("HOME"), ".local", "state"), "yudae", "build")
		for _, makefile in ipairs(os.files(path.join(dir, "*", "Makefile"))) do
			local plugin_dir = path.directory(makefile)
			local id = path.filename(plugin_dir)
			os.execv("make", { "-C", plugin_dir, "OUT=" .. path.join(state, id) })
			print("built " .. id)
		end
	end)

target("plugin-check")
	set_kind("phony")
	set_default(false)
	add_tests("plugins")
	on_test(function ()
		return import("check_plugins").run(root)
	end)
