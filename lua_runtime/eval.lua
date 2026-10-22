-- Preserve nil columns and contain errors raised by a result's __tostring.
local function cell(v)
    local ok, s = pcall(tostring, v)
    if not ok or type(s) ~= 'string' then return '?' end
    return s
end
local function join(ok, ...)
    if not ok then return 'ERROR: ' .. cell((...)) .. '\n' end
    local out = {}
    for i = 1, select('#', ...) do out[i] = cell((select(i, ...))) end
    return table.concat(out, '\t') .. '\n'
end
function kiln_eval(text)
    local chunk, err = loadstring('return ' .. text, '=ipc')
    if chunk == nil then chunk, err = loadstring(text, '=ipc') end
    if chunk == nil then return 'ERROR: ' .. cell(err) .. '\n' end
    return join(pcall(chunk))
end
