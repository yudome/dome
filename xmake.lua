-- global build options and area includes

option("debug")
	set_default(false)
	set_showmenu(true)
	set_description("debug build with symbols")

option("small")
	set_default(false)
	set_showmenu(true)
	set_description("optimize for size")

option("llvm")
	set_default(true)
	set_showmenu(true)
	set_description("use LLVM in zig (false builds faster, runs slower)")

option("headless")
	set_default(false)
	set_showmenu(true)
	set_description("build only the headless daemon")

-- runtime install prefix: PREFIX wins, then ~/.local, xmake -o still wins
function yudae_prefix()
	return os.getenv("PREFIX") or path.join(os.getenv("HOME"), ".local")
end

add_moduledirs("modules")

includes("daemon", "shell", "plugins", "vm")
