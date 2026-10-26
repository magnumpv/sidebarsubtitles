-- Loads the real sidebarsubtitles/main.lua against a stubbed mp and checks which rows it draws.
-- There is no standalone Lua here, so run it in a headless mpv (no window):
--   timeout 30 mpv --no-config --vo=null --ao=null --idle=yes --script=tests/follow-current-line-test.lua
-- It prints "ok" and exits 0, or prints the failed check and exits 1.

local mainLua   = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("tests/[^/]*$", "sidebarsubtitles/main.lua")
local tmpDir    = os.tmpname()
local pointer   = {x = 1100, y = 300} --inside the sidebar the whole time, so hover must not block following
local props     = {path = "video.mkv", sid = 1, ["video-margin-ratio-right"] = 0.12}
local track     = {type = "sub", id = 1, lang = "eng", external = true, ["external-filename"] = tmpDir.."/in.ass", codec = "ass", title = "t"}
local commands  = {} --subprocess args
local realUtils = require "mp.utils"
local keys      = {}
local observe   = {}
local timers    = {}
local typed     = "" --the search text
local asyncResult
local osdText
local hooks
local overlay
local ass       = setmetatable({text = ""}, {__index = function(_, name)

    return name == "append" and function(self, str) self.text = self.text..str end or function() end
end})

local function shell(args)

    local quoted = {}

    for _, arg in ipairs(args) do table.insert(quoted, "'"..arg.."'") end

    return os.execute(table.concat(quoted, " ").." >/dev/null 2>&1")
end

local function timer(func)

    local t = {func = func, kill = function(self) self.killed = true end}

    table.insert(timers, t)

    return t
end

local function ts(seconds)

    local cs = math.floor(seconds * 100 + 0.5)

    return string.format("%d:%02d:%02d.%02d", math.floor(cs / 360000), math.floor(cs / 6000) % 60, math.floor(cs / 100) % 60, cs % 100)
end

local function writeSubtitles(path)

    local starts, lines = {}, {}

    for i = 1, 100 do starts[i] = i * 2 end

    starts[51] = 100.4 --two cues inside the same second

    for i, start in ipairs(starts) do

        local text = (i == 41) and "line 40" or "line "..i --identical text in consecutive cues

        table.insert(lines, string.format("Dialogue: 0,%s,%s,Default,,0,0,0,,%s", ts(start), ts(start + 1.5), text))
    end

    local f = assert(io.open(path, "w"))

    f:write("[Events]\n"..table.concat(lines, "\n").."\n")
    f:close()
end

local fake = setmetatable({

    create_osd_overlay = function() overlay = {update = function() end} return overlay end,
    get_osd_size       = function() return 1280, 720 end,
    get_mouse_pos      = function() return pointer.x, pointer.y end,
    get_property       = function(name) return props[name] end,
    get_property_number = function(name, default) return props[name] or default end,
    get_property_native = function() return {track} end,
    get_script_directory = function() return (mainLua:gsub("/main.lua$", "")) end,
    commandv           = function(cmd, name, value) if cmd == "set" then props[name] = value end end,
    osd_message        = function(text) osdText = text end,
    command_native_async = function(cmd, callback)

        table.insert(commands, cmd.args)
        callback(true, asyncResult, nil)
    end,
    observe_property   = function(name, _, func) observe[name] = func end,
    add_key_binding    = function(_, name, func) keys[name] = func end,
    add_forced_key_binding = function(_, name, func) keys[name] = func end,
    remove_key_binding = function(name) keys[name] = nil end,
    add_periodic_timer = function(_, func) return timer(func) end,
    add_timeout        = function(_, func) return timer(func) end,
    command_native     = function(cmd)

        if cmd.name == "subprocess" then

            table.insert(commands, cmd.args)

            return {status = shell(cmd.args) and 0 or 1}
        end

        return cmd[2]
    end,
}, {__index = function() return function() end end})

package.loaded["mp"]         = fake
package.loaded["mp.options"] = {read_options = function() end}
package.loaded["mp.utils"]   = {join_path = function(a, b) return a.."/"..b end, format_json = function() return "" end, parse_json = realUtils.parse_json}
package.loaded["mp.assdraw"] = {ass_new = function() ass.text = "" return ass end}

--the real fastutf8 reads the global mp for its map file directory

local realMp = mp
mp           = fake
package.loaded["fastutf8"] = dofile((mainLua:gsub("main.lua$", "fastutf8.lua")))
mp           = realMp
package.loaded["input"]      = {get_text = function() return typed end, texts = function() return "", "", 0 end, init = function() end, reset = function() typed = "" end, default = function() end, calculate_offset = function() end,

    bindings = function(h) hooks = h return {x = {key = "x", func = function() end}} end
}

-- reads the first visible row, the selected row and the row count from the drawn overlay

local function check(label, first, selected, count)

    local rows = {}

    for n in overlay.data:gmatch("}#(%d+)") do table.insert(rows, tonumber(n)) end

    local got  = string.format("first=%s selected=%s rows=%d", tostring(rows[1]), tostring(overlay.data:match("\\b1\\1c&H000000&\\fs%d+}#(%d+)")), #rows)
    local want = string.format("first=%d selected=%s rows=%d", first, tostring(selected), count or 10)

    assert(got == want, string.format("%s: got %s, want %s", label, got, want))
end

--the property holds the playing cue and the observer gets the same value, like in mpv

local function play(startTime)

    props["sub-start"] = startTime

    observe["sub-start"]("sub-start", startTime)
end

local function run()

    assert(os.remove(tmpDir) and shell({"mkdir", "-p", tmpDir}))
    writeSubtitles(tmpDir.."/in.ass")

    local getenv = os.getenv

    os.getenv = function(name) return name == "TEMP" and tmpDir or getenv(name) end

    assert(loadfile(mainLua))()

    --open while paused in the middle of cue 30, the property is 7 ms off the cached ASS time

    props["sub-start"] = 60.007

    keys.sidebarsubtitles_primary()
    check("open mid-cue", 26, 30)

    --the observer uses the notified value, not the stale property

    observe["sub-start"]("sub-start", 62)
    check("notified value", 27, 31)

    props["sub-start"] = nil

    play(80)
    check("cue 40", 36, 40)
    play(82)
    check("same text as the previous cue", 37, 41)

    play(100)
    check("cue 50", 46, 50)
    play(100.4)
    check("cue 51 in the same second", 47, 51)

    play(2)
    check("first cue", 1, 1)
    play(6)
    check("start clamp", 1, 3)
    play(192)
    check("end clamp", 91, 96)
    play(200)
    check("last cue", 91, 100)
    play(61)
    check("no cue starts here", 91, 100)

    --a resize drag is left alone and followed once it ends

    pointer.x = 965
    keys.sidebarsubtitles_sidebarclick({event = "down"})
    play(120)
    check("during a drag", 91, 100)
    keys.sidebarsubtitles_sidebarclick({event = "up"})
    check("after a drag", 56, 60)

    --an active search is left alone and the sync resumes when it ends

    pointer.x, pointer.y = 1100, 20
    keys.sidebarsubtitles_sidebarclick({event = "down"})
    play(140)
    check("during a search", 56, 60)
    pointer.y = 40
    keys.sidebarsubtitles_sidebarclick({event = "down"})
    check("after a search", 66, 70)

    --manual scroll stays while the pointer is in the sidebar, new cues only move the selection

    pointer.y = 300
    keys.sidebarsubtitles_sidebarscrolldown()
    check("manual scroll", 67, 70)
    observe["mouse-pos"]()
    check("pointer move", 67, 70)
    play(150)
    check("next cue after scroll", 67, 75)
    keys.sidebarsubtitles_sidebarscrolldown()
    check("scroll during playback", 68, 75)

    --leaving the sidebar follows playback again

    pointer.x = 300
    observe["mouse-pos"]()
    check("pointer left the sidebar", 71, 75)

    --a row click after a scroll seeks there and follows from it

    pointer.x = 1100
    keys.sidebarsubtitles_sidebarscrolldown()
    keys.sidebarsubtitles_sidebarclick({event = "down"})
    play(146)
    check("follows after a row click", 69, 73)

    --zoom changes the row count and the current cue is centered at once

    play(200)
    keys.sidebarsubtitles_sidebarzoomin()
    check("zoom", 92, 100, 9)
    keys.sidebarsubtitles_sidebarzoomout()
    check("zoom out", 91, 100)

    --filtered results (line 7 and lines 70 to 79) keep their position and only get the selection

    pointer.y = 20
    keys.sidebarsubtitles_sidebarclick({event = "down"})
    typed = "line 7"
    hooks.after_changes()
    timers[#timers].func()
    check("filtered results", 1, nil)
    play(150)
    check("editing a search", 1, nil)
    pointer.y = 40
    keys.sidebarsubtitles_sidebarclick({event = "down"})
    check("filtered selection", 1, 7)
    play(152)
    check("filtered selection follows", 1, 8)
    play(80)
    check("playing cue not in the results", 1, 8)

    --closing the sidebar in the middle of a search leaves nothing of it behind

    pointer.y = 20
    keys.sidebarsubtitles_sidebarclick({event = "down"})
    typed = "line 9"
    hooks.after_changes()
    keys.sidebarsubtitles_primary()
    assert(not keys.sidebarsubtitles_searchx and not keys.sidebarsubtitles_sidebarclick, "bindings left after close")

    for _, t in ipairs(timers) do assert(t.killed, "timer left after close") end

    play(120)
    keys.sidebarsubtitles_primary()
    check("reopen after a search", 56, 60)

    --closing gives back the user's video margin

    keys.sidebarsubtitles_primary()
    assert(props["video-margin-ratio-right"] == 0.12, "video margin not restored")

    --a failed external track is not extracted from the video and is not kept for the next open

    track.codec, track["external-filename"] = "webvtt", tmpDir.."/missing.vtt"
    asyncResult = {status = 1, stderr = "boom"}
    keys.sidebarsubtitles_primary()
    assert(not keys.sidebarsubtitles_sidebarclick and osdText == "Subtitle not found!", "failed track opened")

    for _, args in ipairs(commands) do assert(not table.concat(args, " "):find("0:s:", 1, true), "external track extracted from the video") end

    --an external ASS is read in place, without a copy

    local f = assert(io.open(tmpDir.."/b.ass", "w"))

    f:write("[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,f(x) a\n")
    f:close()

    track.codec, track["external-filename"] = "ass", tmpDir.."/b.ass"
    commands = {}
    keys.sidebarsubtitles_primary()
    assert(keys.sidebarsubtitles_sidebarclick, "next track not opened")

    for _, args in ipairs(commands) do assert(not table.concat(args, " "):find("b.ass", 1, true), "external ASS copied") end

    --search text is literal, and one-char and multi-char matches are highlighted

    for search, want in pairs({["("] = "f{\\c&H00FFFF&}({\\c&HFFFFFF&}x) a", x = "f({\\c&H00FFFF&}x{\\c&HFFFFFF&}) a", ["(x"] = "f{\\c&H00FFFF&}(x{\\c&HFFFFFF&}) a"}) do

        typed = search
        observe["mouse-pos"]()
        assert(overlay.data:find(want, 1, true), "highlight of "..search)
    end
end

local ok, err = xpcall(run, debug.traceback)

assert(tmpDir:find("^/tmp/lua_%w+$"))
shell({"rm", "-rf", tmpDir})

print(ok and "ok" or err)
mp.commandv("quit", ok and "0" or "1")
