-- vm image task and host doctor

local dir = os.scriptdir()
local root = path.directory(dir)

task("vm")
	set_category("action")
	set_menu {
		usage = "xmake vm images|ensure|overlay|snapshot|restore|backup|list|bench [tag]",
		description = "build vm images with mkosi and bench them",
		options = {
			{ nil, "args", "vs", nil, "vm arguments" },
			{ nil, "force", "k", nil, "force the vm image step" },
			{ nil, "snapshot", "kv", nil, "pin the Arch Linux Archive date" },
		}
	}
	on_run(function ()
		import("vm_tasks").vm(dir, root)
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
		import("vm_tasks").doctor(dir, root)
	end)
