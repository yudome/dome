local util = import("util")
local trim = util.trim
function fsd(dir, out)
	local uid = (os.iorunv("id", { "-u" }) or ""):gsub("%s+", "")
	if uid ~= "0" then
		raise("run as root, after deciding to install the helper")
	end
	io.write("Install yudae-fsd and its polkit action? [y/N] ")
	local answer = io.read()
	if not answer or not answer:match("^[yY]") then
		print("nothing installed")
		raise("nothing installed")
	end
	local prefix = os.getenv("PREFIX") or "/usr/local"
	local bindir = path.join(prefix, "lib", "yudae")
	local repo = path.directory(dir)
	os.execv("install", { "-d", bindir, "/usr/share/polkit-1/actions", "/usr/lib/systemd/system" })
	os.execv("install", { "-m", "0755", path.join(out, "yudaemond"), path.join(bindir, "yudaemond") })
	os.execv("install", { "-m", "0644", path.join(repo, "systemd", "system", "yudae-fsd.socket"), "/usr/lib/systemd/system/yudae-fsd.socket" })
	os.execv("install", { "-m", "0644", path.join(repo, "systemd", "system", "yudae-fsd.service"), "/usr/lib/systemd/system/yudae-fsd.service" })
	os.execv("install", { "-m", "0644", path.join(repo, "systemd", "system", "org.yudae.policy"), "/usr/share/polkit-1/actions/org.yudae.policy" })
	os.execv("systemctl", { "daemon-reload" })
	os.execv("systemctl", { "enable", "--now", "yudae-fsd.socket" })
	print("installed yudae-fsd")
end
function greeter()
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
end
function uninstall_greeter()
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
end
