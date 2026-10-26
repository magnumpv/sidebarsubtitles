--v1.1
local utils          = require "mp.utils"
local utf8           = {}
utf8.pattern         = "[%z\1-\127\194-\244][\128-\191]*"
local paths          = {

    script       = mp.get_script_directory()..package.config:sub(1, 1),
    lower_file   = "lc_map.json",
    upper_file   = "uc_map.json",
    unicode_file = "unicode.txt"
}
local map            = {}
local current_locale = ""

local function prev_size(str, pos)

    pos     = pos - 1
    local b = str:byte(pos)

    while pos > 1 and b >= 128 and b <= 191 do

        pos = pos - 1
        b   = str:byte(pos)
    end

    return pos
end

local function next_size(str, pos)

    local b = str:byte(pos)

    if b < 128 then

        return 1
    elseif b < 224 then

        return 2
    elseif b < 240 then

        return 3
    end

    return 4
end

local function utf8pattern(pt)

    local i, bytes = 1, #pt
    local content  = ""
    local escape   = false

    while i <= bytes do

        local start = i
        i           = i + next_size(pt, i)
        local char  = pt:sub(start, i - 1)

        if char == "%" then

            escape = true
        elseif escape then

            escape = false
        elseif char == "." then

            char = utf8.pattern
        end

        content = content..char
    end

    return content
end

local function add_specials()

    if current_locale == "" then return end

    if current_locale == "tr" or current_locale == "tur" then

        for _, v in pairs({{"ı", "I"}, {"i", "İ"}}) do

            local lower, upper = v[1], v[2]
            map.s_lower[upper] = lower
            map.s_upper[lower] = upper
        end
    elseif current_locale == "de" or current_locale == "deu" then

        for _, v in pairs({{"ß", "SS"}}) do

            local lower, upper = v[1], v[2]
            map.s_upper[lower] = upper
        end
    end
end

function utf8.set_locale(lang_code)

    current_locale = lang_code
    map.s_lower    = {}
    map.s_upper    = {}

    add_specials()
end

function utf8.create_mapping_files()

    local h = io.open(paths.script..paths.unicode_file, "r")

    if not h then error("Unicode file not found.") return end

    local lower_map = {}
    local upper_map = {}

    for line in h:lines() do

        if line:sub(1,1) ~= "#" and line ~= "" then

            local fields = {}

            for field in line:gmatch("([^;]*);?") do

                table.insert(fields, field)
            end

            local code        = fields[1]
            local description = fields[2]
            local category    = fields[3]
            local lowercase   = fields[14]

            if category == "Lu" and lowercase ~= "" and description and description:find("LETTER") then

                code      = utf8.char(code)
                lowercase = utf8.char(lowercase)

                if lower_map[code] then

                    print(string.format("[LC] LETTER ALREADY DEFINED: %s=%s", lower_map[code], lowercase))
                else

                    lower_map[code] = lowercase
                end

                if upper_map[lowercase] then

                    print(string.format("[UC] LETTER ALREADY DEFINED: %s=%s", upper_map[lowercase], code))
                else

                    upper_map[lowercase] = code
                end
            end
        end
    end

    local json_text

    json_text = utils.format_json(lower_map)

    h = io.open(paths.script..paths.lower_file, "w")

    h:write(json_text)
    h:close()

    json_text = utils.format_json(upper_map)

    h = io.open(paths.script..paths.upper_file, "w")

    h:write(json_text)
    h:close()
end

function utf8.enable_case_mapping()

    local load_map_file = function(path)

        local h       = io.open(path, "r")
        local content = h:read("*a")

        h:close()

        return utils.parse_json(content)
    end

    map.lower   = load_map_file(paths.script..paths.lower_file)
    map.upper   = load_map_file(paths.script..paths.upper_file)
    map.s_lower = {}
    map.s_upper = {}
end

function utf8.reset()

    map            = {}
    current_locale = ""
end

function utf8.char(hex)

    local cp = tonumber(hex, 16)

    if cp < 128 then return string.char(cp) end

    local s = cp % 64
    cp      = (cp - s) / 64

    if cp < 32 then return string.char(192 + cp, 128 + s) end

    local s2 = cp % 64
    cp       = (cp - s2) / 64

    if cp < 16 then return string.char(224 + cp, 128 + s2, 128 + s) end

    local s3 = cp % 64

    return string.char(240 + (cp - s3) / 64, 128 + s3, 128 + s2, 128 + s)
end

function utf8.chars(str)

    local i, bytes = 1, #str

    return function()

        if i > bytes then return nil end

        local start = i
        i           = i + next_size(str, i)

        return str:sub(start, i - 1)
    end
end

function utf8.rchars(str)

    local i = #str + 1

    return function()

        if i <= 1 then return nil end

        local stop = i - 1
        i          = prev_size(str, i)

        return str:sub(i, stop)
    end
end

function utf8.len(str)

    local n, i, bytes = 0, 1, #str

    while i <= bytes do

        n = n + 1
        i = i + next_size(str, i)
    end

    return n
end

function utf8.match(str, pattern)

    local si, li = string.find(str, utf8pattern(pattern))

    if not si then return nil end

    return string.sub(str, si, li)
end

function utf8.gfind(str, pattern)

    local n, pos, bytes = 0, 1, #str
    local matches       = {}
    local si, li
    local results

    results = {string.find(str, utf8pattern(pattern))}

    if results[1] then

       while pos <= bytes do

            if not results[1] then break end

            n          = n + 1
            local size = next_size(str, pos)

            if pos == results[1] then

                si = n

            end

            if (pos + size - 1) == results[2] then

                li = n

                if not results[3] then results[3] = string.sub(str, results[1], results[2]) end

                results[1] = si
                results[2] = li

                table.insert(matches, results)

                results = {string.find(str, utf8pattern(pattern), pos + 1)}
            end

            pos = pos + size
       end
    end

    local i = 0

    return function()

        i = i + 1

        if matches[i] then return table.unpack(matches[i]) end
    end
end

function utf8.find(str, pattern)

    local si, li = string.find(str, utf8pattern(pattern))

    if not si then return nil end

    local n, i, bytes = 0, 1, li

    while i <= bytes do

        n          = n + 1
        local size = next_size(str, i)

        if i == si              then si = n       end
        if (i + size - 1) == li then li = n break end

        i = i + size
    end

    return si, li
end

function utf8.sub(str,sstart,send)

    local content     = ""
    local n, i, bytes = 0, 1, #str
    local si, li      = 0, 0

    sstart = math.max(sstart, 1)

    while i <= bytes do

        n          = n + 1
        local size = next_size(str, i)

        if n == sstart then si = i                  end
        if n == send   then li = i + size - 1 break end

        i = i + size
    end

    if si == 0 and li == 0 then return "" end

    return str:sub(si, (li > 0) and li or bytes)
end

function utf8.lower(str)

    if not map.lower then return "" end

    local content  = ""
    local i, bytes = 1, #str

    while i <= bytes do

        local size = next_size(str, i)
        local char = string.sub(str, i, i + size - 1)

        content = content..(map.s_lower[char] or map.lower[char] or char)

        i = i + size
    end

    return content
end

function utf8.upper(str)

    if not map.upper then return "" end

    local content  = ""
    local i, bytes = 1, #str

    while i <= bytes do

        local size = next_size(str, i)
        local char = string.sub(str, i, i + size - 1)

        content = content..(map.s_upper[char] or map.upper[char] or char)

        i = i + size
    end

    return content
end

return utf8