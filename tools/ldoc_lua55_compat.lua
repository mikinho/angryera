-- LDoc 1.5.0 assigns to a generic-for control variable in ldoc.html.
-- Lua 5.5 makes those variables const, so the released LDoc crashes while
-- rendering. This loader applies the same local-variable fix present in the
-- tested upstream revision b8b574c8a67019e26a423af1b8c141d306ab58b2 without
-- modifying the contributor's installed LuaRocks files.

local searchers = rawget(package, "searchers") or package.loaders
local searchpath = rawget(package, "searchpath")
if type(searchers) == "table" and type(searchpath) == "function" then
    table.insert(searchers, 2, function(moduleName)
        if moduleName ~= "ldoc.html" and moduleName ~= "ldoc.html.ldoc_ltp" and moduleName ~= "ldoc.markdown" then
            return nil
        end

        local path, searchError = searchpath(moduleName, package.path)
        if not path then
            return searchError
        end

        local sourceFile, openError = io.open(path, "rb")
        if not sourceFile then
            return openError
        end
        local source = sourceFile:read("*a")
        sourceFile:close()

        local patched = source
        local replacements = 0
        local count

        if moduleName == "ldoc.html" then
            patched, count = patched:gsub(
                "for tag in doc%.module_info_tags%(%) do",
                "for raw_tag in doc.module_info_tags() do\n      local tag = raw_tag",
                1
            )
            replacements = replacements + count
            patched, count = patched:gsub(
                "for name in tp:gmatch%(\"%[%^|%]%+\"%) do",
                "for raw_name in tp:gmatch(\"[^|]+\") do\n         local name = raw_name",
                1
            )
            replacements = replacements + count
        elseif moduleName == "ldoc.html.ldoc_ltp" then
            patched, count = patched:gsub(
                "# for kind, items in module%.kinds%(%) do",
                "# for raw_kind, items in module.kinds() do\n# local kind = raw_kind",
                1
            )
            replacements = replacements + count
            patched, count = patched:gsub(
                "# for kind, mods, type in ldoc%.kinds%(%) do",
                "# for raw_kind, mods, raw_type in ldoc.kinds() do\n# local kind, type = raw_kind, raw_type",
                1
            )
            replacements = replacements + count
            patched, count = patched:gsub(
                "# for kind, mods in ldoc%.kinds%(%) do",
                "# for raw_kind, mods in ldoc.kinds() do\n# local kind = raw_kind",
                1
            )
            replacements = replacements + count
        else
            patched, count = patched:gsub(
                "for k,v in pairs%(escape_table%) do",
                "for raw_k,v in pairs(escape_table) do\n\t\tlocal k = raw_k",
                1
            )
            replacements = replacements + count
        end

        if replacements == 0 then
            return nil
        end

        local loader, compileError = load(patched, "@" .. path, "t", _ENV)
        if not loader then
            error(compileError, 0)
        end
        return loader, path
    end)
end
