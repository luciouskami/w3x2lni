local w3xparser = require 'w3xparser'
local progress = require 'progress'

local table_concat = table.concat
local ipairs = ipairs
local string_char = string.char
local pairs = pairs
local table_sort = table.sort
local table_insert = table.insert
local math_floor = math.floor
local wtonumber = w3xparser.tonumber
local select = select
local table_unpack = table.unpack
local os_clock = os.clock
local type = type
local next = next

local report
local w2l
local metadata
local keys
local remove_unuse_object
local object

local function to_type(tp, value)
    if tp == 0 then
        if not value or value == 0 then
            return nil
        end
        return value
    elseif tp == 1 or tp == 2 then
        if not value or value == 0 then
            return nil
        end
        return ('%.4f'):format(value):gsub('[0]+$', ''):gsub('%.$', '')
    elseif tp == 3 then
        if not value then
            return
        end
        if value:find(',', nil, false) then
            value = '"' .. value .. '"'
        end
        return value
    end
end

local function get_index_data(tp, ...)
    local null
    local l = table.pack(...)
    for i = l.n, 1, -1 do
        local v = to_type(tp, l[i])
        if v then
            l[i] = v
            null = ''
        else
            l[i] = null
        end
    end
    if #l == 0 then
        return
    end
    return table_concat(l, ',')
end

local function add_data(obj, meta, value, keyval)
    local key = meta.field
    if meta.index then
        -- TODO: 有点奇怪的写法
        if meta.index == 1 then
            local value = get_index_data(meta.type, obj[meta.key..':1'], obj[meta.key..':2'])
            if not value then
                return
            end
            keyval[#keyval+1] = {key:sub(1,-3), value}
        end
        return
    end
    if meta.appendindex then
        if type(value) == 'table' then
            local len = 0
            for n in pairs(value) do
                if n > len then
                    len = n
                end
            end
            if len == 0 then
                return
            end
            if len > 1 then
                keyval[#keyval+1] = {key..'count', len}
            end
            local flag
            for i = 1, len do
                local key = key
                if i > 1 then
                    key = key .. (i-1)
                end
                if value[i] then
                    flag = true
                    if meta.concat then
                        keyval[#keyval+1] = {key, value[i]}
                    else
                        keyval[#keyval+1] = {key, to_type(meta.type, value[i])}
                    end
                end
            end
            if not flag then
                keyval[#keyval] = nil
            end
        else
            if not value then
                return
            end
            if meta.concat then
                keyval[#keyval+1] = {key, value}
            else
                keyval[#keyval+1] = {key, to_type(meta.type, value)}
            end
        end
        return
    end
    if meta.concat then
        if value and value ~= 0 then
            keyval[#keyval+1] = {key, value}
        end
        return
    end
    if type(value) == 'table' then
        value = get_index_data(meta.type, table_unpack(value))
        if value == '' then
            value = ','
        end
    else
        value = to_type(meta.type, value)
    end
    if value then
        keyval[#keyval+1] = {key, value}
    end
end

local function create_keyval(obj)
    local keyval = {}
    for _, key in ipairs(keys) do
        if key ~= 'editorsuffix' and key ~= 'editorname' then
            local data = obj[key]
            if data then
                add_data(obj, metadata[key], data, keyval)
            end
        end
    end
    return keyval
end

local function stringify_obj(str, obj)
    local keyval = create_keyval(obj)
    if #keyval == 0 then
        return
    end
    table_sort(keyval, function(a, b)
        return a[1]:lower() < b[1]:lower()
    end)
    local empty = true
    str[#str+1] = ('[%s]'):format(obj._id)
    for _, kv in ipairs(keyval) do
        local key, val = kv[1], kv[2]
        if val ~= '' then
            if type(val) == 'string' then
                val = val:gsub('\r\n', '|n'):gsub('[\r\n]', '|n')
            end
            str[#str+1] = key .. '=' .. val
            empty = false
        end
    end
    if empty then
        str[#str] = nil
    else
        str[#str+1] = ''
    end
end

local displaytype = {
    unit = '单位',
    ability = '技能',
    item = '物品',
    buff = '魔法效果',
    upgrade = '科技',
    doodad = '装饰物',
    destructable = '可破坏物',
}

local function get_displayname(o)
    if o._type == 'buff' then
        return displaytype[o._type], o._id, o.bufftip or o.editorname or ''
    elseif o._type == 'upgrade' then
        return displaytype[o._type], o._id, o.name[1] or ''
    else
        return displaytype[o._type], o._id, o.name or ''
    end
end

local function report_failed(obj, key, tip, info)
    report.n = report.n + 1
    if not report[tip] then
        report[tip] = {}
    end
    if report[tip][obj._id] then
        return
    end
    local type, id, name = get_displayname(obj)
    report[tip][obj._id] = {
        ("%s %s %s"):format(type, id, name),
        ("%s %s"):format(key, info),
    }
end

local function check_string(s)
    return type(s) == 'string' and s:find(',', nil, false) and s:find('"', nil, false)
end

local function prebuild_data(obj, key, r)
    if not obj[key] then
        return
    end
    if type(obj[key]) == 'table' then
        object[key] = {}
        local t = {}
        for k, v in pairs(obj[key]) do
            if check_string(v) then
                report_failed(obj, metadata[key].field, '文本内容同时包含了逗号和双引号', v)
                object[key][k] = v
            else
                t[k] = v
            end
        end
        if not next(object[key]) then
            object[key] = nil
        end
        if next(t) then
            r[key] = t
        end
    else
        if check_string(obj[key]) then
            report_failed(obj, metadata[key].field, '文本内容同时包含了逗号和双引号', obj[key])
            object[key] = obj[key]
        else
            r[key] = obj[key]
        end
    end
end

local function prebuild_obj(name, obj)
    if remove_unuse_object and not obj._mark then
        return
    end
    local r = {}
    for _, key in ipairs(keys) do
        prebuild_data(obj, key, r)
    end
    if next(r) then
        r._id = obj._id
        return r
    end
end

local function prebuild_merge(obj, a, b)
    for k, v in pairs(b) do
        if k == '_id' then
            goto CONTINUE
        end
        if type(v) == 'table' then
            if type(a[k]) == 'table' then
                for i, iv in pairs(v) do
                    if a[k][i] ~= iv then
                        report_failed(obj, metadata[k].field, '文本内容和另一个对象冲突', '--> ' .. a._id)
                        if obj[k] then
                            obj[k][i] = iv
                        else
                            obj[k] = {[i] = iv}
                        end
                    end
                end
            else
                report_failed(obj, metadata[k].field, '文本内容和另一个对象冲突', '--> ' .. a._id)
                for i, iv in pairs(v) do
                    if obj[k] then
                        obj[k][i] = iv
                    else
                        obj[k] = {[i] = iv}
                    end
                end
            end
        else
            if a[k] ~= v then
                report_failed(obj, metadata[k].field, '文本内容和另一个对象冲突', '--> ' .. a._id)
                obj[k] = v
            end
        end
::CONTINUE::
    end
end

local function prebuild(type, input, output, list)
    for name, obj in pairs(input) do
        local r = prebuild_obj(name, obj)
        if r then
            r._type = type
            name = name:lower()
            if output[name] then
                prebuild_merge(obj, output[name], r)
            else
                output[name] = r
                list[#list+1] = r._id
            end
        end
    end
end

local function update_constant(type)
    metadata = w2l:metadata()[type]
    keys = w2l:keydata()[type]
end

return function(w2l_, slk, report_, obj)
    w2l = w2l_
    report = report_
    object = obj
    remove_unuse_object = w2l.config.remove_unuse_object
    local txt = {}
    local list = {}
    for _, type in ipairs {'ability', 'buff', 'unit', 'item', 'upgrade'} do
        list[type] = {}
        update_constant(type)
        prebuild(type, slk[type], txt, list[type])
    end
    local r = {}
    for _, type in ipairs {'ability', 'buff', 'unit', 'item', 'upgrade'} do
        update_constant(type)
        local str = {}
        table_sort(list[type])
        for _, name in ipairs(list[type]) do
            stringify_obj(str, txt[name:lower()])
        end
        r[type] = table_concat(str, '\r\n')
    end
    return r
end
