local vendor = io.open("/sys/class/dmi/id/sys_vendor")
local guest = vendor ~= nil and (vendor:read("l") or ""):find("QEMU") ~= nil

if vendor then vendor:close() end

return {
    guest = guest,
}
