local M = {}

local function parse_mi(str, pos)
    pos = pos or 1

    local function parse_string(p)
        p = p + 1
        local start = p
        local parts = {}
        while p <= #str do
            local c = str:sub(p, p)
            if c == "\\" then
                parts[#parts + 1] = str:sub(start, p - 1)
                p = p + 1
                parts[#parts + 1] = str:sub(p, p)
                start = p + 1
                p = p + 1
            elseif c == '"' then
                parts[#parts + 1] = str:sub(start, p - 1)
                return table.concat(parts), p + 1
            else
                p = p + 1
            end
        end
        error("unterminated string at pos " .. start)
    end

    local function parse_bare(p)
        local start = p
        while p <= #str do
            local c = str:sub(p, p)
            if c == ',' or c == '}' or c == ']' then
                break
            end
            p = p + 1
        end
        return str:sub(start, p - 1), p
    end

    local function parse_value(p)
        local c = str:sub(p, p)
        if c == '"' then
            return parse_string(p)
        elseif c == '{' then
            return parse_tuple(p)
        elseif c == '[' then
            return parse_list(p)
        else
            return parse_bare(p)
        end
    end

    function parse_tuple(p)
        p = p + 1
        local result = {}
        if str:sub(p, p) == '}' then return result, p + 1 end
        while true do
            local eq = str:find("=", p)
            local key = str:sub(p, eq - 1)
            local val
            val, p = parse_value(eq + 1)
            result[key] = val
            if str:sub(p, p) == '}' then return result, p + 1 end
            p = p + 1
        end
    end

    function parse_list(p)
        p = p + 1
        local result = {}
        if str:sub(p, p) == ']' then return result, p + 1 end

        local c = str:sub(p, p)
        if c == '"' or c == '{' or c == '[' then
            while true do
                local val
                val, p = parse_value(p)
                result[#result + 1] = val
                if str:sub(p, p) == ']' then return result, p + 1 end
                p = p + 1
            end
        else
            while true do
                local eq = str:find("=", p)
                local key = str:sub(p, eq - 1)
                local val
                val, p = parse_value(eq + 1)
                result[#result + 1] = val
                if str:sub(p, p) == ']' then return result, p + 1 end
                p = p + 1
            end
        end
    end

    return parse_value(pos)
end

function M.parse_mi_record(line)
    local pos = 1

    local token_str = line:match("^(%d+)")
    local token = nil
    if token_str then
        token = tonumber(token_str)
        pos = pos + #token_str
    end

    pos = pos + 1

    local class_end = line:find(",", pos)
    local class
    if class_end then
        class = line:sub(pos, class_end - 1)
        pos = class_end + 1
    else
        class = line:sub(pos)
        return token, class, {}
    end

    local results = {}
    while pos <= #line do
        local eq = line:find("=", pos)
        if not eq then break end
        local key = line:sub(pos, eq - 1)
        local val
        val, pos = parse_mi(line, eq + 1)
        results[key] = val
        if pos <= #line and line:sub(pos, pos) == "," then
            pos = pos + 1
        end
    end

    return token, class, results
end

return M
