-- shell checks and native plugin

local dir = os.scriptdir()
local root = path.directory(dir)

target("shell-checks")
	set_kind("phony")
	set_default(false)
	add_tests("static")
	on_test(function ()
		return import("checks_static").run(root, dir)
	end)

target("shell-app")
	set_kind("phony")
	set_default(false)
	add_tests("app")
	on_test(function ()
		return import("checks_app").run(root, dir)
	end)

target("shell-lint")
	set_kind("phony")
	set_default(false)
	add_tests("qml")
	on_test(function ()
		return import("checks_qml").run(root, dir)
	end)

target("shell-face")
	set_kind("phony")
	set_default(false)
	add_tests("face")
	on_test(function ()
		return import("checks_face").run()
	end)

includes("native")

task("link")
	set_category("action")
	set_menu {
		usage = "xmake link",
		description = "link the config, hypr, systemd units and icons into $HOME",
	}
	on_run(function ()
		import("shell_link").run(root)
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

task("lockscreen")
	set_category("action")
	set_menu {
		usage = "xmake lockscreen",
		description = "open the lock screen and greeter preview",
	}
	on_run(function ()
		local envs = {
			QML_IMPORT_PATH = path.join(os.getenv("HOME"), ".local", "lib", "yudae", "qml") .. ":" .. path.join(dir, "native", "qml"),
		}
		os.execv("quickshell", { "-p", path.join(dir, "app-lockscreen.qml") }, { envs = envs })
	end)

target("greeter")
	set_kind("phony")
	set_default(false)
	after_install(function ()
		import("install").greeter()
	end)
	after_uninstall(function ()
		import("install").uninstall_greeter()
	end)
