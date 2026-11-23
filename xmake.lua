-- xmake tasks: link lint bench hypr vm doctor (see scripts/tasks.sh)

target("checks")
    set_kind("phony")
    add_tests("daemon")
    add_tests("qml")
    add_tests("plugins")
    add_tests("apps")
    add_tests("idle-spawn")
    on_test(function (target, opt)
        local name = opt.name:match("/(.+)$")

        if name == "daemon" then
            return os.execv("sh", {"-c", "cd daemon && zig build test"}, {try = true}) == 0
        end

        if name == "qml" then
            return os.execv("sh", {"-c", "for f in $(find shell -name '*.check.js' -not -path '*/cache/*'); do node \"$f\" || exit 1; done"}, {try = true}) == 0
        end

        if name == "apps" then
            return os.execv("sh", {"-c", "scripts/app-check"}, {try = true}) == 0
        end

        if name == "plugins" then
            return os.execv("sh", {"-c", "scripts/plugin-check"}, {try = true}) == 0
        end

        if name == "idle-spawn" then
            return os.execv("sh", {"-c", "scripts/yudae spawn-check --seconds 10"}, {try = true}) == 0
        end

        return false
    end)

includes("shell/native")
