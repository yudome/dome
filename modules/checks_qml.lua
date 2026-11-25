function run(root, dir)
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
end
