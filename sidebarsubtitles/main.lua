--[[

╔════════════════════════════════╗
║      MPV sidebarsubtitles      ║
║             v1.0.8             ║
╚════════════════════════════════╝

## Required ##
FFmpeg

]]

local mp              = require 'mp'
local assdraw         = require 'mp.assdraw'
local options         = require 'mp.options'
local utils           = require "mp.utils"
local utf8            = require 'fastutf8'
local input           = require 'input'
local config          = {

    width                  = 315,
    padding_x              = 14,
    padding_y              = 7,
    max_len                = 38,
    font_scale             = 1.0,
    bar_width              = 3,
    bar_min_height         = 50,
    hide_loaded_subtitle   = false,
    round                  = 15,
    sort_lines             = true,
    remove_repeating_lines = true,
    use_timestamp          = false
}
local offset          = 1
local browsing        = false
local currentIndex    = 0
local subtitles       = {}
local tempSubtitles   = {}
local sidebarEnabled  = false
local search          = {enabled = false, refresh = false, timer = nil, resultTimer = nil, processing = false,}
local drag            = {active = false, hover = false, offset = 0}
local data            = {}
local currentSubtitle = {}
local customThemes    = {}
local mouse           = {x = 0, y = 0}
local colors          = {

    background       = "161616",
    rowText          = "FFFFFF",
    rowUpperText     = "888888",
    rowHover         = "0B0B0B",
    rowSelected      = "FFFFFF",
    rowSelectedText  = "000000",
    rowBorder        = "272727",
    searchBackground = "676767",
    searchText       = "888888",
    highlight        = "FFFF00",
    scroll           = "888888"
}
local overlay         = mp.create_osd_overlay("ass-events")

options.read_options(config, "sidebarsubtitles")

local function clampScale(scale)

    return math.max(0.7, math.min(2.5, scale))
end

local fontScale = clampScale(config.font_scale)

--the sidebar width changes at runtime by dragging its left edge, config.max_len is the char count at defaultWidth

local defaultWidth  = 315
local minWidth      = 200
local maxWidthRatio = 0.7
local grabWidth     = 6
local sidebarWidth  = config.width

--the cached ASS file has centisecond times while sub-start has the source time, so a cue matches its start within this many seconds

local startTolerance = 0.02

local function getSubtitleInfo(subtitleType)

    local currentSubId = 0

    if subtitleType == "primary" then

        currentSubId = mp.get_property_number("sid", 0)
    elseif subtitleType == "secondary" then

        currentSubId = mp.get_property_number("secondary-sid", 0)
    end

    if currentSubId == 0 then return nil end

    local tracks = mp.get_property_native("track-list")

    for _, track in ipairs(tracks) do

        if track.type == "sub" and track.id == currentSubId then

            return track
        end
    end
end

local function assColor(rgbColor)

    local r, g, b = rgbColor:sub(1, 2), rgbColor:sub(3, 4), rgbColor:sub(5, 6)

    return b..g..r
end

for key in pairs(colors) do colors[key] = assColor(colors[key]) end

local function strip(str)

    str = str
    :gsub("%{.-%}", "")
    :gsub("\\[Nnh]", " ")
    :gsub("%s+", " ")
    :gsub("^%s*(.-)%s*$", "%1")

    return str
end

local function runCommand(args)

    return mp.command_native({

        name           = 'subprocess',
        playback_only  = false,
        capture_stdout = true,
        capture_stderr = true,
        args           = args
    })
end

local function log(str)

    if type(str) == "table" then

        print(utils.format_json(str))
    else

        print(str)
    end
end

local function runAsync(cmd, handleSuccess, handleFail)

    local proc = mp.command_native_async(cmd, function(_, result, _)

        if result.status == 0 then

            handleSuccess()
        else

            handleFail(result.stderr)
        end
    end)
end

local function tableCopy(t)

    local copy = {}

    for k, v in pairs(t) do copy[k] = v end

    return copy
end

local function ts2ms(ts)

    local h, m, s, ms = ts:match("^(%d?%d):(%d%d):(%d%d)%.(%d%d%d?)$")

    if not h then return 0 end

    if #ts == 10 then ms = ms.."0" end

    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(ms) / 1000
end

local function ms2ts(secs)

    if secs == 0 then return "0:00:00.00" end

    local h  = math.floor(secs / 3600)
    local m  = math.floor((secs % 3600) / 60)
    local s  = secs % 60
    local ms = math.floor((secs - math.floor(secs)) * 1000)

    return string.format("%d:%02d:%02d.%02d", h, m, s, ms)
end

local function hash(str)

    local h1, h2, h3 = 0, 0, 0

    for i = 1, #str do

        local b = str:byte(i)

        h1 = (h1 * 31 + b) % 2^32
        h2 = (h2 * 37 + b) % 2^32
        h3 = (h3 * 41 + b) % 2^32
    end

    return string.format("%08x%08x%08x", h1, h2, h3)
end

local function reset()

    data              = {}
    subtitles         = {}
    tempSubtitles     = {}
    offset            = 1
    browsing          = false
    currentIndex      = 0
    currentSubtitle   = {}
    search.enabled    = false
    search.processing = false
    drag.active       = false
    drag.hover        = false
    mouse             = {x = 0, y = 0}
end

local function getPath(key)

    local fullPath
    local isWindows = package.config:sub(1, 1) ~= '/'
    local seperator = isWindows and "//" or "\\"
    local paths = {

        hash        = nil,
        temp        = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp",
        cacheFolder = "mpvsidebarsubtitles",
        filename    = "<id>-<lang>"
    }

    paths.hash = paths.hash or hash(mp.get_property("path"))

    if key == "cache" then

        fullPath = utils.join_path(paths.temp, paths.cacheFolder..seperator..paths.hash)
    elseif key == "subtitlefile" then

        fullPath = utils.join_path(paths.temp, paths.cacheFolder..seperator..paths.hash..seperator..paths.filename:gsub("<id>", currentSubtitle.id):gsub("<lang>", currentSubtitle.lang)..".ass")
    elseif key == "mergedfile" then

        fullPath = utils.join_path(paths.temp, "mpvdualsubtitles"..seperator..paths.hash..seperator.."merged.ass")
    end

    fullPath = fullPath:gsub("\\", "/")
    fullPath = mp.command_native({'expand-path', fullPath})

    return fullPath
end

local function truncate(str, breakingPoint)

    local maxLen = math.max(1, math.floor(config.max_len * (sidebarWidth / defaultWidth) / fontScale))

    if not breakingPoint and maxLen > utf8.len(str) then return str end

    local n         = 0
    local inTags    = false
    local breaked   = false
    local chars     = {}
    local lastSpace = 0
    local k         = 0

    for c in utf8.chars(str) do table.insert(chars, c) end

    local deleteThis = false
    local l          = 1

    for i in ipairs(chars) do

        if chars[i] == "{" then inTags = true end

        if not inTags then

            k = k + 1

            if breakingPoint and breakingPoint > 0 then

                if k == maxLen + 1 then deleteThis = true end

                if k == breakingPoint and l == 1 then

                    deleteThis = false
                    k          = 1
                    l          = l + 1
                end
            else

                if k == maxLen + 1 then

                    if l == 1 then k = 1 end

                    l = l + 1
                end
            end

            if l > 2 then deleteThis = true end

            if not deleteThis then

                if l < 3 and chars[i] == " " then lastSpace = i end

                if k == 1 and l == 2 then

                    if chars[i] == "-" then

                        chars[i] = "\\N"..chars[i]
                    else

                        if chars[i] == " " or (chars[i + 1] and chars[i + 1] == " ") then

                            chars[i] = chars[i].."\\N"
                        else

                            if lastSpace > 0 then

                                k                = k + (i - lastSpace + 1)
                                chars[lastSpace] = chars[lastSpace].."\\N"
                            else

                                chars[i] = chars[i].."\\N"
                            end
                        end
                    end
                end
            else

                chars[i] = ""
            end

            --print("i="..i.." | k="..k.." | l="..l.." | lastSpace="..lastSpace..' | char="'..chars[i]..'"')
        end

        if chars[i] and chars[i] == "}" then inTags = false end
    end

    return table.concat(chars, "")
end

local function highlighter(str, selected)

    if input.get_text() == "" or search.processing then return str end

    text               = utf8.lower(str)
    local searchedText = utf8.lower(input.get_text())
    local matches      = {}

    for si, li in utf8.gfind(text, (searchedText:gsub("%p", "%%%0"))) do

        table.insert(matches, {startIndex = si, lastIndex = li})
    end

    if #matches == 0 then return str end

    local n       = 0
    local m       = 1
    local content = ""

    for c in utf8.chars(str) do

        n              = n + 1
        local preTags  = ""
        local postTags = ""

        if matches[m].startIndex == n then

            preTags = string.format("{\\c&H%s&}", colors.highlight)

            if selected then preTags = preTags.."{\\bord1\\3c&H000000&\\blur1}" end
        end

        if matches[m].lastIndex == n then

            postTags = string.format("{\\c&H%s&}", selected and colors.rowSelectedText or colors.rowText)

            if selected then postTags = postTags.."{\\bord0\\blur0}" end
            if matches[m + 1] then m = m + 1 end
        end

        content = content..preTags..c..postTags
    end

    return content
end

local function updateOverlay(content)

    if overlay.data == content and overlay.res_x == data.screenWidth and overlay.res_y == data.screenHeight then return end

    overlay.data  = content
    overlay.res_x = data.screenWidth
    overlay.res_y = data.screenHeight
    overlay.z     = 2000

    overlay:update()
end

local function convertTime(time)

    time = ms2ts(time)

    if not config.use_timestamp then

        time = time:gsub("^0:", "")
        time = time:gsub("^0", "")
        time = time:gsub("%.%d+", "")
        time = time:gsub(":", ".")
    end

    return time
end

local function drawSidebar()

    local ass   = assdraw.ass_new()
    local lineY = data.screenHeight - data.contentArea

    --background

    ass:new_event()
    ass:pos(data.videoWidth, 0)
    ass:append(string.format("{\\bord0\\1c&H%s&}", colors.background))
    ass:draw_start()
    ass:rect_cw(0, 0, sidebarWidth, data.screenHeight)
    ass:draw_stop()

    --no results found

    if #subtitles == 0 then

        ass:new_event()
        ass:pos(data.videoWidth + config.padding_x, lineY + config.padding_y)
        ass:append(string.format("{\\bord0\\an7\\b0\\1c&H%s&\\fs%s}", colors.rowText, data.bottomFontSize))
        ass:append("No results found.")
    end

    --search

    local searchBoxX, searchBoxY = data.videoWidth + config.padding_x, config.padding_y
    local searchBoxW, searchBoxH = sidebarWidth - config.padding_x * 2, data.searchBoxHeight
    local searchTextAreaWidth    = searchBoxW - data.searchBoxPaddingX * 2

    input.calculate_offset(data.screenWidth, data.screenHeight, searchTextAreaWidth)

    local searchText, searchTextWithCursor, searchTextOffset = input.texts()

    if search.enabled then

        --box

        ass:new_event()
        ass:pos(searchBoxX, searchBoxY)
        ass:append(string.format("{\\bord0\\1c&H%s&}", colors.searchBackground))
        ass:draw_start()
        ass:round_rect_cw(0, 0, searchBoxW, searchBoxH, config.round, config.round)
        ass:draw_stop()

        --text

       ass:new_event()
       ass:pos(searchBoxX + data.searchBoxPaddingX - searchTextOffset, searchBoxY + data.searchBoxPaddingY)
       ass:append(string.format("{\\clip(%s,%s,%s,%s)\\bord0}", searchBoxX + data.searchBoxPaddingX, searchBoxY, searchBoxX + searchBoxW - data.searchBoxPaddingX, searchBoxY + searchBoxH))
       ass:append(searchText)

        --cursor

       ass:new_event()
       ass:pos(searchBoxX + data.searchBoxPaddingX - searchTextOffset, config.padding_y + data.searchBoxPaddingY)
       ass:append(searchTextWithCursor)
    else

        --box

        ass:new_event()
        ass:pos(searchBoxX, searchBoxY)
        ass:append(string.format("{\\bord0\\1c&H%s&\\alpha&HC8&}", colors.searchBackground))
        ass:draw_start()
        ass:round_rect_cw(0, 0, searchBoxW, searchBoxH, config.round, config.round)
        ass:draw_stop()

        --text

        ass:new_event()
        ass:append(string.format("{\\bord0\\1c&H%s&\\fs%s}", colors.searchText, data.searchFontSize))

        if input.get_text() ~= "" then

            ass:pos(searchBoxX + data.searchBoxPaddingX - searchTextOffset, config.padding_y + data.searchBoxPaddingY)
            ass:append(string.format("{\\clip(%s,%s,%s,%s)}", searchBoxX + data.searchBoxPaddingX, searchBoxY, searchBoxX + searchBoxW - data.searchBoxPaddingX, searchBoxY + searchBoxH))
            ass:append(searchText)
        else

            ass:pos(searchBoxX + data.searchBoxPaddingX, config.padding_y + data.searchBoxPaddingY)
            ass:append("Search...")
        end

        --icon

        ass:new_event()
        ass:pos(searchBoxX + sidebarWidth - config.padding_x * 2 - 33, config.padding_y + data.searchBoxHeight / 2 - 8)
        ass:append(string.format("{\\bord0\\1c&H%s&\\fs7\\p1\\fscx40\\fscy40}", colors.searchText))
        ass:append("m 16 0 b 24 0 32 8 32 16 b 32 24 24 32 16 32 b 8 32 0 24 0 16 b 0 8 8 0 16 0 m 30 28 l 25 32 l 33 40 l 38 36 m 6 16 b 6 22 10 26 16 26 b 22 26 26 22 26 16 b 26 10 22 6 16 6 b 10 6 6 10 6 16")
    end

    local firstRow = true

    for i = offset, offset + data.lineCount - 1 do

        local selected = false

        if not search.processing and currentIndex == i then selected = true end

        --border

        if not firstRow then

           ass:new_event()
           ass:pos(data.videoWidth, lineY)
           ass:append(string.format("{\\bord0\\1c&H%s&}", colors.rowBorder))
           ass:draw_start()
           ass:rect_cw(0, 0, sidebarWidth, data.borderHeight)
           ass:draw_stop()
        end

        --selected

        if selected then

            --box

            ass:new_event()
            ass:pos(data.videoWidth, lineY + data.borderHeight)
            ass:append(string.format("{\\bord0\\1c&H%s&}", colors.rowSelected))
            ass:draw_start()
            ass:rect_cw(0, 0, sidebarWidth, data.lineHeight - data.borderHeight)
            ass:draw_stop()

            --icon

            ass:new_event()
            ass:pos(data.videoWidth + 3, lineY + data.borderHeight + data.lineHeight / 2 - 5)
            ass:append(string.format("{\\bord0\\1c&H%s&}", colors.rowSelectedText))
            ass:draw_start()

            local triX, triY = 0, 0
            local triW, triH = 80, 100

            ass:append(string.format("m %f %f l %f %f l %f %f l %f %f", triX, triY, triX, triY + triH, triX + triW, triY + triH/2, triX, triY))
            ass:draw_stop()
        else

            --hover

            if not search.processing and not drag.active and mouse.x >= data.videoWidth and mouse.y and mouse.y > lineY and mouse.y < lineY + data.lineHeight then

                ass:new_event()
                ass:pos(data.videoWidth, lineY + data.borderHeight)
                ass:append(string.format("{\\bord0\\1c&H%s&}", selected and colors.rowSelected or colors.rowHover))
                ass:draw_start()
                ass:rect_cw(0, 0, sidebarWidth, data.lineHeight - data.borderHeight)
                ass:draw_stop()
            end
        end

        --top text

        ass:new_event()
        ass:pos(data.videoWidth + config.padding_x, lineY + config.padding_y)
        ass:append(string.format("{\\bord0\\an7\\b1\\1c&H%s&\\fs%s}", (selected) and colors.rowSelectedText or colors.rowUpperText, data.topFontSize))

        if search.processing then ass:append("{\\alpha&HC8&}") end

        ass:append(string.format("#%d", i))

        ass:new_event()
        ass:pos(data.videoWidth + sidebarWidth - config.padding_x, lineY + config.padding_y)
        ass:append(string.format("{\\b0\\an9\\bord0\\1c&H%s&\\fs%s}", selected and colors.rowSelectedText or colors.rowUpperText, data.topFontSize))

        if search.processing then ass:append("{\\alpha&HC8&}") end

        ass:append(string.format("%s - %s", convertTime(subtitles[i].startTime), convertTime(subtitles[i].endTime)))

        --bottom text

        ass:new_event()
        ass:pos(data.videoWidth + config.padding_x, lineY + config.padding_y + data.topFontSize + data.lineMargin)
        ass:append(string.format("{\\bord0\\an7\\b0\\1c&H%s&\\fs%s}", selected and colors.rowSelectedText or colors.rowText, data.bottomFontSize))

        if search.processing then ass:append("{\\alpha&HC8&}") end

        local text          = subtitles[i].text
        local breakingPoint = utf8.find(text, "...%-%s")
        text                = highlighter(text, selected)
        text                = truncate(text, breakingPoint and breakingPoint + 3 or breakingPoint)

        ass:append(text)

        lineY    = lineY + data.lineHeight
        firstRow = false
    end

    --scroll

    if #subtitles > data.lineCount then

        lineY            = data.screenHeight - data.contentArea + data.borderHeight
        local barX       = data.videoWidth + sidebarWidth - config.bar_width
        local barHeight  = math.max(data.maxOffset * 0.1, config.bar_min_height)
        local barY       = (data.contentArea - barHeight - data.borderHeight) * ((offset - 1) / (data.maxOffset - 1))

        ass:new_event()
        ass:pos(barX, lineY + barY)
        ass:append(string.format("{\\1c&H%s&\\bord0}", colors.scroll))
        ass:draw_start()
        ass:rect_cw(0, 0, config.bar_width, barHeight)
        ass:draw_stop()
    end

    --resize handle

    if drag.hover or drag.active then

        ass:new_event()
        ass:pos(data.videoWidth, 0)
        ass:append(string.format("{\\1c&H%s&\\bord0}", colors.scroll))
        ass:draw_start()
        ass:rect_cw(0, 0, config.bar_width, data.screenHeight)
        ass:draw_stop()
    end

    updateOverlay(ass.text)
end

local function scaled(size)

    return math.floor(size * fontScale + 0.5)
end

local function fillData()

    data.searchBoxPaddingX              = 20
    data.searchBoxPaddingY              = scaled(7)
    data.searchBoxHeight                = scaled(30)
    data.searchFontSize                 = scaled(17)
    data.topFontSize                    = scaled(13)
    data.bottomFontSize                 = scaled(17)
    data.lineMargin                     = 5
    data.borderHeight                   = 1
    data.screenWidth, data.screenHeight = mp.get_osd_size()
    data.videoWidth                     = data.screenWidth - sidebarWidth
    data.lineHeight                     = data.topFontSize + data.bottomFontSize * 2 + data.lineMargin + config.padding_y * 2
    data.contentArea                    = data.screenHeight - (data.searchBoxHeight + config.padding_y * 2)
    data.lineCount                      = math.floor(data.contentArea / data.lineHeight)
    data.lineCount                      = data.lineCount > #subtitles and #subtitles or data.lineCount
    data.maxOffset                      = #subtitles - data.lineCount + 1
    local gap                           = #subtitles ~= data.lineCount and (data.contentArea - data.lineHeight * data.lineCount) / data.lineCount or 0
    data.lineHeight                     = data.lineHeight + gap
end

local function detectUOSC()

    local scriptPath = mp.command_native({'expand-path', '~~/scripts/uosc'})
    local f          = io.open(scriptPath..'/main.lua', 'r')

    if f then

        f:close()

        return true
    end

    return false
end

local function setVideoMargin()

    mp.commandv("set", "video-margin-ratio-right", sidebarWidth / data.screenWidth)

    if customThemes.uosc then mp.commandv('script-message-to', 'uosc', 'sidebarsubtitles', data.videoWidth) end
end

--a press and drag over the sidebar would move a borderless window instead of reaching the bindings

local function setWindowDragging(allow)

    local value = allow and defaultWindowDragging or "no"

    if mp.get_property("window-dragging") ~= value then mp.set_property("window-dragging", value) end
end

local function togglePlayerControls()

    if defaultSubMargin == nil then defaultSubMargin = mp.get_property("sub-use-margins") end
    if defaultVideoMargin == nil then defaultVideoMargin = mp.get_property_number("video-margin-ratio-right", 0) end
    if defaultWindowDragging == nil then defaultWindowDragging = mp.get_property("window-dragging") end

    if sidebarEnabled then

        setWindowDragging(true)
        mp.set_property("sub-use-margins", defaultSubMargin)
        mp.commandv("set", "video-margin-ratio-right", defaultVideoMargin)

        if customThemes.uosc then

            mp.commandv('script-message-to', 'uosc', 'sidebarsubtitles', 0)

        else

            mp.command("script-message osc-visibility auto")
        end
    else

        mp.set_property("sub-use-margins", "no")
        setVideoMargin()

        if not customThemes.uosc then

            mp.command("script-message osc-visibility never")
        end
    end
end

local function findIndexByStart(startTime)

    local index   = 0
    local nearest = startTolerance

    for i, subtitle in ipairs(subtitles) do

        local distance = math.abs(subtitle.startTime - startTime)

        if distance < nearest then

            index   = i
            nearest = distance
        end
    end

    return index
end

--selects the cue that starts at startTime (default: the playing one) and centers it, the caller draws
--a filtered list or a list the user scrolled only gets the selection, its position stays

local function syncCurrentLine(startTime)

    if drag.active or search.enabled or search.processing then return false end

    startTime = startTime or mp.get_property_number(currentSubtitle.group == "p" and "sub-start" or "secondary-sub-start")

    local index = startTime and findIndexByStart(startTime) or 0

    if index == 0 then return false end

    currentIndex = index

    if #tempSubtitles > 0 or browsing then return true end

    offset = math.max(1, math.min(data.maxOffset, index - math.floor((data.lineCount - 1) / 2)))

    return true
end

local function initSidebar()

    local overrides   = mp.get_property("sub-ass-style-overrides")
    local hidePrimary = "Primary.AlphaLevel=255"

    if not sidebarEnabled then

        utf8.enable_case_mapping()
        utf8.set_locale(currentSubtitle.lang)

        fillData()

        input.init()
        input.font_size = data.searchFontSize

        setBindings("sidebar")
        togglePlayerControls()
        syncCurrentLine()
        drawSidebar()

        if config.hide_loaded_subtitle then

            if currentSubtitle.title == "merged.ass" then

                overrides = (overrides == "") and hidePrimary or overrides..","..hidePrimary

                mp.set_property("sub-ass-style-overrides", overrides)
            else

                mp.set_property_native(currentSubtitle.group == "p" and "sub-visibility" or "secondary-sub-visibility", "no")
            end
        end
    else

        --an active search must not outlive the sidebar, its bindings and timers would reach the next one

        if search.enabled then unsetBindings("search") end
        if search.timer then search.timer:kill() end
        if search.resultTimer then search.resultTimer:kill() end

        input.reset()
        utf8.reset()

        unsetBindings("sidebar")
        updateOverlay("")
        togglePlayerControls()

        if config.hide_loaded_subtitle then

            if currentSubtitle.title == "merged.ass" then

                overrides = overrides:gsub(",?"..hidePrimary:gsub("%.", "%%."), "")

                mp.set_property("sub-ass-style-overrides", overrides)
            else

                mp.set_property_native(currentSubtitle.group == "p" and "sub-visibility" or "secondary-sub-visibility", "yes")
            end
        end

        reset()

        collectgarbage()
    end

    sidebarEnabled = not sidebarEnabled
end

local function tryGetSubtitles()

    local merged = false
    local file

    if currentSubtitle.title == "merged.ass" then

        file   = io.open(getPath("mergedfile"), "r")
        merged = true
    end

    if not file then

        if currentSubtitle.external then

            if currentSubtitle.codec == "ass" then

                file = io.open(currentSubtitle.filename, "r")
            else

                local targetFile = getPath("subtitlefile")
                local result     = runCommand({"ffmpeg", "-y", "-i", currentSubtitle.filename, "-c:s", "ass", targetFile})

                if result.status == 0 then file = io.open(targetFile, "r") end
            end
        else

            file = io.open(getPath("subtitlefile"), "r")
        end
    end

    if not file then

        mp.osd_message("Subtitle not found!")

        return false
    end

    local content  = file:read("*all")
    local prevLine = {}

    file:close()

    for line in content:gmatch("Dialogue:[^\n]+") do

        local t = {line:match("^Dialogue:%s([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.+)$")}

        if t then

            local deleteThis = false
            t[10]            = strip(t[10])

            if merged and t[4] ~= "Primary" then deleteThis = true end

            if not deleteThis and config.remove_repeating_lines and prevLine then

                if prevLine[10] == t[10] and (prevLine[2] == t[2] or prevLine[3] == t[2]) then deleteThis = true end
            end

            if not deleteThis then table.insert(subtitles, {startTime = ts2ms(t[2]), endTime = ts2ms(t[3]), text = t[10]}) end

            prevLine = t
        end
    end

    if #subtitles == 0 then

        mp.osd_message("The subtitle format is unvalid!")

        return false
    end

    if config.sort_lines then

        table.sort(subtitles, function(a, b)

            return tonumber(a.startTime) < tonumber(b.startTime)
        end)
    end

    mp.osd_message("")

    initSidebar()

    return true
end

local function initSidebarWhenSubtitlesLoaded()

    local tempPath = getPath("cache")

    if not os.rename(tempPath, tempPath) then

        if package.config:sub(1, 1) ~= '/' then
            runCommand({"powershell", "-NoProfile", "-Command", "mkdir", tempPath})
        else
            runCommand({"mkdir", "-p", tempPath})
        end
    end

    local ok

    ok = tryGetSubtitles()

    if ok then return end

    if currentSubtitle.external then

        currentSubtitle = {}

        return
    end

    mp.osd_message("Getting subtitle lines...", 9999)

    local args = {}

    table.insert(args, "ffmpeg")
    table.insert(args, "-i")
    table.insert(args, mp.get_property("path"))

    table.insert(args, "-map")
    table.insert(args, string.format("0:s:%s", currentSubtitle.id - 1))
    table.insert(args, "-c:s")
    table.insert(args, "ass")
    table.insert(args, getPath("subtitlefile"))

    table.insert(args, "-vn")
    table.insert(args, "-an")
    table.insert(args, "-dn")
    table.insert(args, "-y")

    local ffmpegCommand = {

        name           = "subprocess",
        capture_stdout = true,
        capture_stderr = true,
        playback_only  = false,
        args           = args
    }

    local onSubtitleFail = function (result)

        currentSubtitle = {}

        if string.find(result, "No such file or directory") then

            mp.osd_message("No such file or directory.", 3)
        elseif string.find(result, "Failed to set value") then

            mp.osd_message("Wrong subtitle id.", 3)
        elseif string.find(result, "Subtitle encoding currently only possible from text to text or bitmap to bitmap") then

            mp.osd_message("This is not a text-based subtitle.", 3)
        else

            log(result)
            mp.osd_message("See the console for details.", 3)
        end
    end

    runAsync(ffmpegCommand, function()

        if not tryGetSubtitles() then currentSubtitle = {} end
    end, onSubtitleFail)
end

local function toggleSidebar(subtitleType)

    if not currentSubtitle.id then

        local subtitle = getSubtitleInfo(subtitleType)

        if not subtitle then

            mp.osd_message("No subtitle detected.", 3)

            return
        end

        currentSubtitle.id       = subtitle.id
        currentSubtitle.lang     = subtitle.lang and subtitle.lang:gsub("[^a-zA-Z]", "") or "und"
        currentSubtitle.external = subtitle.external
        currentSubtitle.filename = subtitle["external-filename"]
        currentSubtitle.codec    = subtitle.codec
        currentSubtitle.group    = subtitleType == "primary" and "p" or "s"
        currentSubtitle.title    = subtitle.title
    end

    if customThemes.uosc == nil then customThemes.uosc = detectUOSC() end

    if #subtitles == 0 then

        initSidebarWhenSubtitlesLoaded()

        return
    end

    initSidebar()
end

local function mouseInSidebarSearch()

    mouse.x, mouse.y = mp.get_mouse_pos()

    return mouse.x >= (data.videoWidth + config.padding_x) and mouse.x <= (data.videoWidth + sidebarWidth - config.padding_x) and mouse.y >= config.padding_y and mouse.y <= (config.padding_y + data.searchBoxHeight)
end

local function mouseInSidebar()

    mouse.x, mouse.y = mp.get_mouse_pos()

    return mouse.x >= data.videoWidth and mouse.x <= data.videoWidth + sidebarWidth
end

local function mouseInGrabZone()

    mouse.x, mouse.y = mp.get_mouse_pos()

    return mouse.x >= data.videoWidth - grabWidth and mouse.x <= data.videoWidth + grabWidth
end

local function searchResults()

    if not sidebarEnabled then return end

    if #tempSubtitles == 0 then tempSubtitles = tableCopy(subtitles) end

    subtitles          = {}
    local searchedText = utf8.lower(input.get_text())
    local c            = 0

    for i in ipairs(tempSubtitles) do

        if string.find(utf8.lower(tempSubtitles[i].text), searchedText, 1, true) then

            table.insert(subtitles, tempSubtitles[i])
        end
    end

    search.processing = false
    offset            = 1
    currentIndex      = 0

    if #tempSubtitles == #subtitles then tempSubtitles = {} end

    fillData()
    syncCurrentLine()
    drawSidebar()
end

local function enter()

    search.processing = true

    if search.resultTimer then search.resultTimer:kill() end

    search.resultTimer = mp.add_timeout(3, searchResults)
end

local function refreshLayout()

    --input.lua caches the text offset per text and cursor, so rebuild it for the new font size or width

    local searchedText = input.get_text()

    input.reset()
    input.default(searchedText)

    fillData()

    input.font_size = data.searchFontSize
    offset          = math.max(1, math.min(offset, data.maxOffset))

    if not browsing then syncCurrentLine() end

    drawSidebar()
end

local function zoomFont(step)

    fontScale = clampScale(math.floor((fontScale + step) * 100 + 0.5) / 100)

    refreshLayout()
end

local function resizeSidebar(width)

    width = math.max(minWidth, math.min(math.floor(data.screenWidth * maxWidthRatio), width))

    if width == sidebarWidth then return end

    sidebarWidth = width

    refreshLayout()
    setVideoMargin()
end

local function bindingList(section)

    if section == "sidebar" then

        local bindings = {

            click = {

                key  = "mbtn_left",
                func = function (event)

                    if sidebarEnabled then

                        --a press in the grab zone starts a resize drag and the release ends it, every other press is a click

                        if event.event == "repeat" then return end

                        if event.event == "up" then

                            if drag.active then

                                drag.active = false
                                drag.hover  = mouseInGrabZone()

                                if not browsing then syncCurrentLine() end

                                drawSidebar()
                            end

                            return
                        end

                        if mouseInGrabZone() then

                            if event.event == "down" then

                                drag.active = true
                                drag.offset = mouse.x - data.videoWidth

                                drawSidebar()
                            end

                            return
                        end

                        if not search.processing and mouseInSidebar() then

                            local lineY = data.screenHeight - data.contentArea

                            for i = offset, offset + data.lineCount - 1 do

                                if mouse.y and mouse.y > lineY and mouse.y < lineY + data.lineHeight then

                                    currentIndex = i
                                    browsing     = false

                                    mp.commandv("seek", subtitles[i].startTime + 0.01, "absolute+exact")

                                    drawSidebar()

                                    break
                                end

                                lineY = lineY + data.lineHeight
                            end
                        end

                        if mouseInSidebarSearch() then

                            search.enabled = true
                            search.refresh = true

                            setBindings("search")

                            if search.timer then search.timer:kill() end

                            search.timer = mp.add_periodic_timer(0.05, function()

                                if search.refresh then

                                    drawSidebar()

                                    search.refresh = false
                                end
                            end)
                        elseif search.enabled then

                            search.enabled = false

                            unsetBindings("search")

                            if search.timer then search.timer:kill() end

                            syncCurrentLine()
                            drawSidebar()
                        end
                    end
                end,
                opts = {complex = true}
            },

            scrollup = {

                key  = "wheel_up",
                func = function ()

                    if sidebarEnabled and not search.processing and mouseInSidebar() then

                        if offset > 1 then offset = offset - 1 end

                        browsing = true

                        drawSidebar()
                    end
                end,
                opts = nil
            },

            scrolldown = {

                key  = "wheel_down",
                func = function ()

                    if sidebarEnabled and not search.processing and mouseInSidebar() then

                        if data.maxOffset and offset < data.maxOffset then offset = offset + 1 end

                        browsing = true

                        drawSidebar()
                    end
                end,
                opts = nil
            },

            zoomin = {

                key  = "ctrl+wheel_up",
                func = function ()

                    if sidebarEnabled and not search.processing and mouseInSidebar() then zoomFont(0.1) end
                end,
                opts = nil
            },

            zoomout = {

                key  = "ctrl+wheel_down",
                func = function ()

                    if sidebarEnabled and not search.processing and mouseInSidebar() then zoomFont(-0.1) end
                end,
                opts = nil
            },
        }

        return bindings

    elseif section == "search" then

        local searchBindings = input.bindings({

            after_changes = function()

                search.refresh = true

                enter()
            end
        })

        return searchBindings
    end
end

function setBindings(section)

    for name, binding in pairs(bindingList(section)) do mp.add_forced_key_binding(binding.key, "sidebarsubtitles_"..section..name, binding.func, binding.opts) end
end

function unsetBindings(section)

    for name in pairs(bindingList(section)) do mp.remove_key_binding("sidebarsubtitles_"..section..name) end
end

--the start changes with every cue, even when two cues have the same text

mp.observe_property("sub-start", "number", function(_, startTime)

    if sidebarEnabled and currentSubtitle.group == "p" and startTime and syncCurrentLine(startTime) then drawSidebar() end
end)

mp.observe_property("secondary-sub-start", "number", function(_, startTime)

    if sidebarEnabled and currentSubtitle.group == "s" and startTime and syncCurrentLine(startTime) then drawSidebar() end
end)

mp.observe_property("mouse-pos", "native", function(_, pos)

    if not sidebarEnabled then return end

    if drag.active then

        mouse.x, mouse.y = mp.get_mouse_pos()

        resizeSidebar(data.screenWidth - (mouse.x - drag.offset))

        return
    end

    local hover = mouseInGrabZone()

    --a scrolled list follows playback again once the pointer leaves the sidebar

    if browsing and not hover and (not mouseInSidebar() or (pos and pos.hover == false)) then

        browsing = false

        if syncCurrentLine() then drawSidebar() end
    end

    setWindowDragging(not hover and not mouseInSidebar())

    if hover ~= drag.hover or (not search.processing and mouseInSidebar()) then

        drag.hover = hover

        drawSidebar()
    end
end)

mp.observe_property("sid", "number", function(_, value)

    if sidebarEnabled and currentSubtitle.group == "p" then toggleSidebar("primary") end
end)

mp.observe_property("secondary-sid", "number", function(_, value)

    if sidebarEnabled and currentSubtitle.group == "s" then toggleSidebar("secondary") end
end)

mp.add_key_binding("h",      "sidebarsubtitles_primary",   function() if sidebarEnabled and currentSubtitle.group == "s" then toggleSidebar("secondary") end toggleSidebar("primary")   end)
mp.add_key_binding("Ctrl+h", "sidebarsubtitles_secondary", function() if sidebarEnabled and currentSubtitle.group == "p" then toggleSidebar("primary")   end toggleSidebar("secondary") end)