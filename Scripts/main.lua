-- Trail Map Sign
-- Adds a "Trail Map Sign" to Build > Decorations. Each sign is a Flag decoration that the mod
-- hides and dresses with a wooden board built from engine shapes. The map face is drawn
-- once into a shared render target from the resort's trail curves and lifts, and only redrawn
-- when the player asks (Ctrl+Alt+Y), so there is no per-frame cost.

local UEHelpers = require("UEHelpers")

local MOD = "TrailMapSign"
local liveKey = "SkiEOMods.enabled." .. MOD
local menuOpenKey = "SkiEOMods.keybind.menuOpen"

-- Board size in cm (the map face). The frame, back panel and posts are built around it.
local FACE_W, FACE_H = 420, 300
local FACE_BOTTOM = 110          -- height of the face's lower edge above the ground
local FRAME = 18                 -- frame bar width
local RT_W, RT_H = 2048, 1462    -- map image size (same shape as the face)
local TILT = math.rad(38)        -- 0 = flat top-down map, higher = more "looking at the mountain"

local mapTarget                  -- shared render target, drawn once per refresh
local mapDrawn = false           -- false until a draw into mapTarget has succeeded
local woodMaterial, darkWoodMaterial
local lastModState = true

local function log(msg) print("[TrailMapSign] " .. tostring(msg) .. "\n") end
local function valid(o) return o ~= nil and type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
local function name(s) return UEHelpers.FindOrAddFName(s) end
local function color(r, g, b, a) return { R = r, G = g, B = b, A = a or 1 } end
local function vec(x, y, z) return { X = x, Y = y, Z = z } end
local function v2(x, y) return { X = x, Y = y } end

-- FindFirstOf walks every object in the game, so cache what it finds and, when nothing is there
-- yet (main menu, loading), only look again every couple of seconds.
local tickCount = 0              -- 100 ms ticks of the main loop
local lookups = {}

local function cachedFind(className)
    local e = lookups[className]
    if e and valid(e.obj) then return e.obj end
    if e and tickCount < e.retryAt then return nil end
    local obj = FindFirstOf(className)
    if not valid(obj) then obj = nil end
    lookups[className] = { obj = obj, retryAt = tickCount + 20 }
    return obj
end

local function find(path)
    local o = StaticFindObject(path)
    if not valid(o) and type(LoadAsset) == "function" then pcall(function() o = LoadAsset(path) end) end
    return valid(o) and o or nil
end

local function textOf(t)
    if t == nil then return "" end
    local ok, s = pcall(function() return t:ToString() end)
    if ok and type(s) == "string" then return s end
    return ""
end

--------------------------------------------------------------------------------
-- Reading the resort
--------------------------------------------------------------------------------

local function bezier(c, steps, out)
    local s, k, e = c.StartPoint, c.ControlPoint, c.Endpoint
    for i = 0, steps do
        local t = i / steps
        local a, b, d = (1 - t) * (1 - t), 2 * (1 - t) * t, t * t
        out[#out + 1] = {
            x = a * s.X + b * k.X + d * e.X,
            y = a * s.Y + b * k.Y + d * e.Y,
            z = a * s.Z + b * k.Z + d * e.Z,
        }
    end
end

local function readTrail(info)
    local trail = {
        name = textOf(info.DisplayName),
        difficulty = tonumber(info.PlayerRatedDifficulty) or 255,
        disabled = info.bManuallyDisabled == true,
        lines = {},
        widths = {},   -- corridor width (cm) per line, for drawing the snow ribbon
        outline = nil,
    }
    local function addCurve(c)
        local pts = {}
        bezier(c, 16, pts)
        trail.lines[#trail.lines + 1] = pts
        local w = 1500
        pcall(function() w = (c.CorridorWidth + c.EndCorridorWidth) / 2 end)
        trail.widths[#trail.lines] = w
    end
    addCurve(info.Curve)
    pcall(function()
        local extra = info.AdditionalCurves
        for i = 1, extra:GetArrayNum() do addCurve(extra[i]) end
    end)
    pcall(function() trail.center = { x = info.BowlCenter.X, y = info.BowlCenter.Y, z = info.BowlCenter.Z } end)
    pcall(function()
        local bowl = info.BowlOutline
        local n = bowl:GetArrayNum()
        if n >= 3 then
            local pts = {}
            for i = 1, n do
                local p = bowl[i]
                pts[#pts + 1] = { x = p.X, y = p.Y, z = p.Z }
            end
            pts[#pts + 1] = pts[1]
            trail.outline = pts
        end
    end)
    local mid = info.MidpointPosition
    trail.mid = { x = mid.X, y = mid.Y, z = mid.Z }
    return trail
end

local function readTrails()
    local trails = {}
    local sub = cachedFind("TrailMapSubsystem")
    if not sub then return trails end
    local ok, err = pcall(function()
        sub.RegisteredTrails:ForEach(function(_, value)
            local okT, trail = pcall(readTrail, value:get())
            if okT then trails[#trails + 1] = trail else log("Skipped a trail: " .. tostring(trail)) end
        end)
    end)
    if not ok then log("Could not read trails: " .. tostring(err)) end
    return trails
end

local function readLifts()
    local lifts = {}
    local reg = cachedFind("PlaceableRegistrySubsystem")
    if not reg then return lifts end
    pcall(function()
        local arr = reg.Lifts
        for i = 1, arr:GetArrayNum() do
            local lift = arr[i]
            if valid(lift) and lift.bIsPreview ~= true then
                pcall(function()
                    local a = lift.StartTerminalMesh:K2_GetComponentLocation()
                    local b = lift.EndTerminalMesh:K2_GetComponentLocation()
                    lifts[#lifts + 1] = {
                        name = textOf(lift.InstanceName),
                        a = { x = a.X, y = a.Y, z = a.Z },
                        b = { x = b.X, y = b.Y, z = b.Z },
                    }
                end)
            end
        end
    end)
    return lifts
end

local cachedResortName   -- remembered per map so a refresh never loses it

local function resortName()
    local function nameOf(save)
        local n = ""
        pcall(function() if valid(save) then n = save.ResortName:ToString() end end)
        return n or ""
    end
    local n = ""
    pcall(function()
        local session = cachedFind("GameSessionSubsystem")
        if session then n = nameOf(session.PendingLoadSave) end
    end)
    if n == "" and cachedResortName then return cachedResortName end
    if n == "" then
        for _, save in ipairs(FindAllOf("SkiResortSaveGame") or {}) do
            n = nameOf(save)
            if n ~= "" then break end
        end
    end
    if n == "" then return "Trail Map" end
    cachedResortName = n
    return n
end

--------------------------------------------------------------------------------
-- Drawing the map image
--------------------------------------------------------------------------------

-- The canvas works in linear colour, so palette values are written as normal (sRGB) colours
-- and converted here. Without this everything comes out pale.
local function srgb(r, g, b, a)
    local function lin(c) return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
    return color(lin(r), lin(g), lin(b), a or 1)
end

local DIFF = {
    [0] = { label = "Beginner", core = srgb(0.13, 0.62, 0.27), symbol = "circle" },
    [1] = { label = "Intermediate", core = srgb(0.10, 0.36, 0.78), symbol = "square" },
    [2] = { label = "Expert", core = srgb(0.06, 0.06, 0.07), symbol = "diamond" },
    [3] = { label = "Pro", core = srgb(0.06, 0.06, 0.07), symbol = "double" },
}
local UNRATED = { label = "Unrated", core = srgb(0.45, 0.45, 0.48), symbol = nil }

local INK = srgb(0.10, 0.12, 0.16)
local HEADER = srgb(0.06, 0.20, 0.36)
local GOLD = srgb(0.85, 0.68, 0.30)
local SNOW = srgb(0.97, 0.98, 1.0)
local LEGEND_BG = srgb(0.93, 0.95, 0.97)
local LIFT = srgb(0.62, 0.10, 0.10)

-- Projection: an orthographic view looking uphill and down at TILT, so downhill points toward
-- the bottom of the board and higher ground sits higher on it, like a painted resort map. The
-- view can also be turned a little to make the resort fill the board.
--   u = p . R                (R = viewer's right, horizontal)
--   v = p . S                (S = screen-down: downhill * cos(tilt) - up * sin(tilt))
local function downhillDirection(trails)
    local dx, dy = 0, 0
    for _, t in ipairs(trails) do
        for _, line in ipairs(t.lines) do
            local a, b = line[1], line[#line]
            local hi, lo = a, b
            if b.z > a.z then hi, lo = b, a end
            dx, dy = dx + (lo.x - hi.x), dy + (lo.y - hi.y)
        end
    end
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return 1, 0 end
    return dx / len, dy / len
end

local function makeView(trails, lifts, angle)
    local bx, by = downhillDirection(trails)
    local ca, sa = math.cos(angle), math.sin(angle)
    local dx, dy = bx * ca - by * sa, bx * sa + by * ca
    local ct, st = math.cos(TILT), math.sin(TILT)
    local view = {
        D = { x = dx, y = dy },
        R = { x = dy, y = -dx },                       -- viewer looks uphill; this is their right
        S = { x = dx * ct, y = dy * ct, z = -st },     -- screen-down
    }
    function view.raw(p)
        return p.x * view.R.x + p.y * view.R.y, p.x * view.S.x + p.y * view.S.y + p.z * view.S.z
    end
    local minU, minV, maxU, maxV = math.huge, math.huge, -math.huge, -math.huge
    local function grow(p)
        local u, v = view.raw(p)
        if u < minU then minU = u end
        if u > maxU then maxU = u end
        if v < minV then minV = v end
        if v > maxV then maxV = v end
    end
    for _, t in ipairs(trails) do
        for _, line in ipairs(t.lines) do for _, p in ipairs(line) do grow(p) end end
        if t.outline then for _, p in ipairs(t.outline) do grow(p) end end
    end
    for _, l in ipairs(lifts) do grow(l.a); grow(l.b) end
    view.minU, view.minV, view.maxU, view.maxV = minU, minV, maxU, maxV
    return view
end

-- Map the view's bounds into a pixel box. Returns the point mapper plus what's needed to go
-- back from pixels to the world (for aiming the camera).
local function fitView(view, x0, y0, x1, y1)
    local w, h = math.max(view.maxU - view.minU, 1), math.max(view.maxV - view.minV, 1)
    local scale = math.min((x1 - x0) / w, (y1 - y0) / h)
    local ox = x0 + ((x1 - x0) - w * scale) / 2
    local oy = y0 + ((y1 - y0) - h * scale) / 2
    view.scale, view.ox, view.oy = scale, ox, oy
    return function(p)
        local u, v = view.raw(p)
        return v2(ox + (u - view.minU) * scale, oy + (v - view.minV) * scale)
    end
end

-- Try turning the view up to 30 degrees either way and keep the one that fills the board most.
local function bestView(trails, lifts, x0, y0, x1, y1)
    local best, bestScore
    for deg = -30, 30, 10 do
        local view = makeView(trails, lifts, math.rad(deg))
        local w, h = math.max(view.maxU - view.minU, 1), math.max(view.maxV - view.minV, 1)
        local fill = math.min((x1 - x0) / w, (y1 - y0) / h)
        local score = fill * (1 - math.abs(deg) / 300) -- slight preference for straight uphill
        if not bestScore or score > bestScore then best, bestScore = view, score end
    end
    return best
end

local Draw = {}
local canvasMethodLogged = false

local function isCanvas(o)
    if not valid(o) then return false end
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n == "Canvas"
end

-- BeginDrawCanvasToRenderTarget hands the canvas back through an out parameter. Try the ways
-- UE4SS might expose it, then fall back to the canvas sized to our render target.
function Draw.findCanvas(world, canvasOut)
    local function found(c, how)
        canvasMethodLogged = true
        return c
    end
    if isCanvas(canvasOut) then return found(canvasOut, "out value") end
    if type(canvasOut) == "table" then
        for k, v in pairs(canvasOut) do
            if isCanvas(v) then return found(v, "out table key " .. tostring(k)) end
            if type(v) == "userdata" then
                local okG, g = pcall(function() return v:get() end)
                if okG and isCanvas(g) then return found(g, "out table :get() at key " .. tostring(k)) end
            end
        end
    end
    local okW, wc = pcall(function() return world.CanvasForDrawMaterialToRenderTarget end)
    if okW and isCanvas(wc) then return found(wc, "World.CanvasForDrawMaterialToRenderTarget") end
    for _, c in ipairs(FindAllOf("Canvas") or {}) do
        local okS, match = pcall(function() return c.SizeX == RT_W and c.SizeY == RT_H end)
        if okS and match then return found(c, "FindAllOf by size") end
    end
    -- Nothing worked: log what we have so the next attempt can target it.
    local keys = {}
    if type(canvasOut) == "table" then for k, v in pairs(canvasOut) do keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end end
    log("Canvas lookup failed. out=" .. type(canvasOut) .. " {" .. table.concat(keys, ", ") .. "} world canvas=" ..
        tostring(okW and wc) .. " canvases=" .. #(FindAllOf("Canvas") or {}))
    for _, c in ipairs(FindAllOf("Canvas") or {}) do
        pcall(function() log("  canvas " .. c:GetFullName() .. " size " .. tostring(c.SizeX) .. "x" .. tostring(c.SizeY)) end)
    end
end

function Draw.begin(rt)
    local world = UEHelpers.GetWorld()
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    krl:ClearRenderTarget2D(world, rt, SNOW)
    local ctx, canvasOut, sizeOut = {}, {}, {}
    local ok, err = pcall(function() krl:BeginDrawCanvasToRenderTarget(world, rt, canvasOut, sizeOut, ctx) end)
    if not ok then error("BeginDrawCanvasToRenderTarget failed: " .. tostring(err)) end
    local canvas = Draw.findCanvas(world, canvasOut)
    if not valid(canvas) then
        if ctx.RenderTarget == nil then ctx.RenderTarget = rt end
        pcall(function() krl:EndDrawCanvasToRenderTarget(world, ctx) end)
        error("No drawing canvas after BeginDraw")
    end
    local engine = UEHelpers.GetEngine()
    Draw.world, Draw.krl, Draw.rt, Draw.ctx, Draw.canvas = world, krl, rt, ctx, canvas
    Draw.white = find("/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture")
    Draw.fontBig = engine.LargeFont
    Draw.fontSmall = engine.SmallFont
    if not valid(Draw.fontSmall) then Draw.fontSmall = Draw.fontBig end
end

function Draw.finish()
    local ctx = Draw.ctx or {}
    if ctx.RenderTarget == nil then ctx.RenderTarget = Draw.rt end
    Draw.krl:EndDrawCanvasToRenderTarget(Draw.world, ctx)
    Draw.canvas = nil
end

function Draw.rect(x, y, w, h, c)
    Draw.canvas:K2_DrawTexture(Draw.white, v2(x, y), v2(w, h), v2(0, 0), v2(1, 1), c, 0, 0, v2(0.5, 0.5))
end

function Draw.line(a, b, thick, c)
    Draw.canvas:K2_DrawLine(a, b, thick, c)
end

function Draw.polyline(points, thick, c)
    for i = 2, #points do Draw.line(points[i - 1], points[i], thick, c) end
end

function Draw.textSize(font, text, scale)
    local ok, size = pcall(function() return Draw.canvas:K2_TextSize(font, text, v2(scale, scale)) end)
    if ok and size and size.X then return size.X, size.Y end
    return #text * 9 * scale, 18 * scale
end

function Draw.text(font, text, x, y, scale, c, centre, outline)
    Draw.canvas:K2_DrawText(font, text, v2(x, y), v2(scale, scale), c, 0, color(0, 0, 0, 0), v2(0, 0),
        centre == true, centre == true, outline ~= nil, outline or color(0, 0, 0, 0))
end

-- Largest text scale that fits the box (measured at scale 1).
function Draw.fitScale(font, text, maxW, maxH)
    local w, h = Draw.textSize(font, text, 1)
    if w <= 0 or h <= 0 then return 1 end
    return math.min(maxW / w, maxH / h)
end

-- Scale that makes this font's capital letters about px pixels tall.
function Draw.scaleForHeight(font, px)
    local _, h = Draw.textSize(font, "Hg", 1)
    if h <= 0 then return 1 end
    return px / h
end

function Draw.ngon(cx, cy, radius, sides, c)
    Draw.canvas:K2_DrawPolygon(Draw.white, v2(cx, cy), v2(radius, radius), sides, c)
end

-- Trail difficulty symbols, centred on (cx, cy), size = overall height in pixels.
function Draw.symbol(kind, cx, cy, size)
    local r = size / 2
    local white = color(1, 1, 1)
    if kind == "circle" then
        Draw.ngon(cx, cy, r + 2, 28, white)
        Draw.ngon(cx, cy, r, 28, DIFF[0].core)
    elseif kind == "square" then
        Draw.rect(cx - r - 2, cy - r - 2, size + 4, size + 4, white)
        Draw.rect(cx - r, cy - r, size, size, DIFF[1].core)
    elseif kind == "diamond" then
        Draw.ngon(cx, cy, r * 1.25 + 3, 4, white)
        Draw.ngon(cx, cy, r * 1.25, 4, DIFF[2].core)
    elseif kind == "double" then
        Draw.ngon(cx - r * 0.95, cy, r * 1.1 + 3, 4, white)
        Draw.ngon(cx + r * 0.95, cy, r * 1.1 + 3, 4, white)
        Draw.ngon(cx - r * 0.95, cy, r * 1.1, 4, DIFF[3].core)
        Draw.ngon(cx + r * 0.95, cy, r * 1.1, 4, DIFF[3].core)
    end
end

function Draw.symbolWidth(kind, size)
    if kind == nil then return 0 end
    if kind == "double" then return size * 2.3 end
    if kind == "diamond" then return size * 1.3 end
    return size
end

--------------------------------------------------------------------------------
-- The board image
--------------------------------------------------------------------------------

local function trailLength(t)
    local len = 0
    for _, line in ipairs(t.lines) do
        for i = 2, #line do
            local a, b = line[i - 1], line[i]
            len = len + math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
        end
    end
    return len
end

local function drawBoard(rt)
    local trails, lifts = readTrails(), readLifts()
    local title = resortName()
    local W, H = RT_W, RT_H
    local headerH = math.floor(H * 0.115)
    local legendH = math.floor(H * 0.085)
    local mapTop, mapBottom = headerH + 8, H - legendH - 4
    local mapH = mapBottom - mapTop

    local view, P
    if #trails > 0 or #lifts > 0 then
        view = bestView(trails, lifts, 50, mapTop + 30, W - 50, mapBottom - 20)
        P = fitView(view, 50, mapTop + 30, W - 50, mapBottom - 20)
    end

    Draw.begin(rt)
    local ok, err = pcall(function()
        local font = Draw.fontBig

        ------------------------------------------------------------------ background
        -- Pale sky fading into snow.
        local bands = 32
        local top, bottom = srgb(0.80, 0.88, 0.95), srgb(0.97, 0.98, 1.0)
        for i = 0, bands - 1 do
            local k = math.min(1, (i / (bands - 1)) / 0.6)
            local c = color(top.R + (bottom.R - top.R) * k, top.G + (bottom.G - top.G) * k,
                top.B + (bottom.B - top.B) * k)
            Draw.rect(0, mapTop + mapH * i / bands, W, mapH / bands + 1, c)
        end

        ------------------------------------------------------------------ map
        if not view then
            local s = Draw.fitScale(font, "No trails yet", W * 0.5, 80)
            Draw.text(font, "No trails yet", W / 2, (mapTop + mapBottom) / 2, s, INK, true)
        else
            local function proj(points)
                local out = {}
                for i, p in ipairs(points) do out[i] = P(p) end
                return out
            end
            local function ribbon(widthCm)
                return math.max(10, math.min(60, widthCm * view.scale))
            end

            local drawn = {}
            for _, t in ipairs(trails) do
                local d = DIFF[t.difficulty] or UNRATED
                local shapes, widths = {}, {}
                for i, line in ipairs(t.lines) do
                    shapes[#shapes + 1] = proj(line)
                    widths[#widths + 1] = ribbon(t.widths[i] or 1500)
                end
                local outline = t.outline and proj(t.outline) or nil
                drawn[#drawn + 1] = { t = t, d = d, shapes = shapes, widths = widths, outline = outline,
                    length = trailLength(t) }
            end

            -- Trails as difficulty-coloured ribbons with a dark edge; bowls filled in.
            for _, e in ipairs(drawn) do
                if e.outline and e.t.center then
                    local c = P(e.t.center)
                    for _, p in ipairs(e.outline) do Draw.line(c, p, 36, e.d.core) end
                end
            end
            for _, e in ipairs(drawn) do
                for i, s in ipairs(e.shapes) do Draw.polyline(s, e.widths[i] * 0.6 + 6, INK) end
                if e.outline then Draw.polyline(e.outline, 10, INK) end
            end
            for _, e in ipairs(drawn) do
                for i, s in ipairs(e.shapes) do Draw.polyline(s, e.widths[i] * 0.6, e.d.core) end
                if e.outline then Draw.polyline(e.outline, 6, e.d.core) end
            end

            -- Lifts: dark red cable with a white halo and terminal blocks.
            for _, l in ipairs(lifts) do
                local a, b = P(l.a), P(l.b)
                Draw.line(a, b, 11, color(1, 1, 1))
                Draw.line(a, b, 6, LIFT)
                for _, p in ipairs({ a, b }) do
                    Draw.rect(p.X - 14, p.Y - 14, 28, 28, color(1, 1, 1))
                    Draw.rect(p.X - 11, p.Y - 11, 22, 22, LIFT)
                end
            end

            -- Labels: white tags with the difficulty symbol. Lifts first, then the longest
            -- trails, skipping anything that would overlap.
            local placed = {}
            local function free(x0, y0, x1, y1)
                for _, r in ipairs(placed) do
                    if x0 < r[3] and x1 > r[1] and y0 < r[4] and y1 > r[2] then return false end
                end
                return true
            end
            local textScale = Draw.scaleForHeight(font, 44)
            local function label(text, at, c, symbol)
                if text == "" then return end
                local tw, th = Draw.textSize(font, text, textScale)
                local symSize = th * 0.6
                local symW = Draw.symbolWidth(symbol, symSize)
                local gap = symW > 0 and 12 or 0
                local padX, padY = 12, 5
                local boxW = padX * 2 + symW + gap + tw
                local boxH = th + padY * 2
                local x0, y0 = at.X - boxW / 2, at.Y - boxH / 2
                local x1, y1 = x0 + boxW, y0 + boxH
                if x0 < 4 or x1 > W - 4 or y0 < mapTop or y1 > mapBottom or not free(x0, y0, x1, y1) then return end
                placed[#placed + 1] = { x0 - 6, y0 - 6, x1 + 6, y1 + 6 }
                Draw.rect(x0 - 3, y0 - 3, boxW + 6, boxH + 6, INK)
                Draw.rect(x0, y0, boxW, boxH, color(1, 1, 1))
                if symbol then Draw.symbol(symbol, x0 + padX + symW / 2, at.Y, symSize) end
                Draw.text(font, text, x0 + padX + symW + gap + tw / 2, at.Y, textScale, c, true)
            end
            for _, l in ipairs(lifts) do
                local m = { x = (l.a.x + l.b.x) / 2, y = (l.a.y + l.b.y) / 2, z = (l.a.z + l.b.z) / 2 }
                label(l.name, P(m), LIFT, nil)
            end
            table.sort(drawn, function(a, b) return a.length > b.length end)
            for _, e in ipairs(drawn) do label(e.t.name, P(e.t.mid), INK, e.d.symbol) end
        end

        ------------------------------------------------------------------ header
        Draw.rect(0, 0, W, headerH, HEADER)
        Draw.rect(0, headerH, W, 8, GOLD)
        local titleText = title:upper()
        local ts = Draw.fitScale(font, titleText, W * 0.72, headerH * 0.62)
        Draw.text(font, titleText, W / 2, headerH / 2, ts, color(1, 1, 1), true)
        local sub = "TRAIL MAP"
        local ss = Draw.fitScale(font, sub, W * 0.12, headerH * 0.26)
        local sw = Draw.textSize(font, sub, ss)
        Draw.text(font, sub, W - 40 - sw / 2, headerH / 2, ss, GOLD, true)

        ------------------------------------------------------------------ legend
        local ly = H - legendH
        Draw.rect(0, ly - 4, W, 4, GOLD)
        Draw.rect(0, ly, W, legendH, LEGEND_BG)
        local legendScale = Draw.scaleForHeight(font, legendH * 0.4)
        local cy = ly + legendH / 2
        local items = {
            { sym = "circle", label = DIFF[0].label },
            { sym = "square", label = DIFF[1].label },
            { sym = "diamond", label = DIFF[2].label },
            { sym = "double", label = DIFF[3].label },
            { sym = "lift", label = "Lift" },
        }
        local slot = W / #items
        local symSize = legendH * 0.42
        for i, it in ipairs(items) do
            local tw = Draw.textSize(font, it.label, legendScale)
            local symW = it.sym == "lift" and 90 or Draw.symbolWidth(it.sym, symSize)
            local total = symW + 18 + tw
            local x = slot * (i - 1) + (slot - total) / 2
            if it.sym == "lift" then
                Draw.line(v2(x, cy), v2(x + symW, cy), 6, LIFT)
                Draw.rect(x - 10, cy - 10, 20, 20, LIFT)
                Draw.rect(x + symW - 10, cy - 10, 20, 20, LIFT)
            else
                Draw.symbol(it.sym, x + symW / 2, cy, symSize)
            end
            Draw.text(font, it.label, x + symW + 18 + tw / 2, cy, legendScale, INK, true)
        end

        log(string.format("Drew %d trails and %d lifts", #trails, #lifts))
    end)
    Draw.finish()
    if not ok then error(err) end
end

local function ensureMapTarget()
    if valid(mapTarget) then return mapTarget end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    -- RTF_RGBA8_SRGB = 3, no mips, no UAV
    mapTarget = krl:CreateRenderTarget2D(UEHelpers.GetWorld(), RT_W, RT_H, 3, SNOW, false, false)
    if not valid(mapTarget) then error("Could not create the map image") end
    return mapTarget
end

local function refreshMap()
    local rt = ensureMapTarget()
    local t0 = os.clock()
    mapDrawn = false
    drawBoard(rt)
    mapDrawn = true
    log(string.format("Map drawn in %.0f ms", (os.clock() - t0) * 1000))
end

--------------------------------------------------------------------------------
-- Building the sign
--------------------------------------------------------------------------------

local function spawnMesh(meshPath, location, rotation, scale)
    local world = UEHelpers.GetWorld()
    local cls = StaticFindObject("/Script/Engine.StaticMeshActor")
    local mesh = find(meshPath)
    if not mesh then error("Missing mesh " .. meshPath) end
    local actor = world:SpawnActor(cls, location, rotation)
    if not valid(actor) then error("Spawn failed for " .. meshPath) end
    local comp = actor.StaticMeshComponent
    comp:SetMobility(2) -- Movable, so the mesh can be set at runtime
    comp:SetStaticMesh(mesh)
    comp:SetCollisionEnabled(0)
    pcall(function() comp:SetCastShadow(true) end)
    actor:SetActorScale3D(scale)
    return actor, comp
end

local function woodFor(comp, dark)
    local existing = dark and darkWoodMaterial or woodMaterial
    if valid(existing) then
        comp:SetMaterial(0, existing)
        return
    end
    local parent = find("/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial")
    local mid = comp:CreateDynamicMaterialInstance(0, parent, name(dark and "TrailMapSignWoodDark" or "TrailMapSignWood"))
    if valid(mid) then
        if dark then
            mid:SetVectorParameterValue(name("Color"), color(0.16, 0.09, 0.04))
            darkWoodMaterial = mid
        else
            mid:SetVectorParameterValue(name("Color"), color(0.42, 0.26, 0.11))
            woodMaterial = mid
        end
    end
end

-- The engine plane faces +Z with its image running along +X. Turn it so it faces the viewer
-- (fx, fy) with the image's X along the viewer's right (checked in game).
local function faceRotationAndScale(fx, fy)
    local right = vec(fy, -fx, 0)
    local r = UEHelpers.GetKismetMathLibrary():MakeRotFromXZ(right, vec(fx, fy, 0))
    return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }, vec(FACE_W / 100, FACE_H / 100, 1)
end

local function applyFaceMaterial(comp)
    local parent = find("/Engine/EngineMaterials/Widget3DPassThrough_Opaque.Widget3DPassThrough_Opaque")
    if not parent then error("Missing face material") end
    local mid = comp:CreateDynamicMaterialInstance(0, parent, name("TrailMapSignFace"))
    if not valid(mid) then error("Could not create face material") end
    mid:SetTextureParameterValue(name("SlateUI"), ensureMapTarget())
    -- The face material is unlit, so dim it a little to sit better in snowy daylight and at night.
    pcall(function() mid:SetVectorParameterValue(name("TintColorAndOpacity"), color(0.8, 0.8, 0.8, 1)) end)
end

-- Builds the board around a base actor (the hidden decoration) and attaches every part to
-- it, so the board follows the game's own placement, rotation, moving and saving.
local function buildSign(base)
    local loc = base:K2_GetActorLocation()
    local rot = base:K2_GetActorRotation()
    local yaw = math.rad(rot.Yaw)
    local fx, fy = math.cos(yaw), math.sin(yaw)   -- the board faces the base's forward direction
    local origin = vec(loc.X, loc.Y, loc.Z)
    local parts = {}
    local rx, ry = fy, -fx -- board's right-hand side as seen by the viewer
    local function at(across, out, up)
        return vec(origin.X + rx * across + fx * out, origin.Y + ry * across + fy * out, origin.Z + up)
    end
    local flat = { Pitch = 0, Yaw = rot.Yaw, Roll = 0 }
    local faceMid = FACE_BOTTOM + FACE_H / 2
    local fullW, fullH = FACE_W + 2 * FRAME, FACE_H + 2 * FRAME

    local function attach(actor)
        -- EAttachmentRule::KeepWorld = 1
        actor:K2_AttachToActor(base, name("None"), 1, 1, 1, false)
        parts[#parts + 1] = actor
    end

    local function cube(across, out, up, depth, width, height, dark)
        local a, c = spawnMesh("/Engine/BasicShapes/Cube.Cube", at(across, out, up), flat,
            vec(depth / 100, width / 100, height / 100))
        woodFor(c, dark)
        attach(a)
    end

    -- Posts (buried a metre so they reach the ground on slopes), back panel, frame and cap.
    local postH = FACE_BOTTOM + FACE_H + FRAME + 140
    local postUp = FACE_BOTTOM + FACE_H + FRAME + 40 - postH / 2
    cube(-(FACE_W / 2 - 50), -16, postUp, 22, 22, postH, true)
    cube(FACE_W / 2 - 50, -16, postUp, 22, 22, postH, true)
    cube(0, -5, faceMid, 10, fullW, fullH, true)
    cube(0, 0, FACE_BOTTOM + FACE_H + FRAME / 2, 16, fullW, FRAME, false)
    cube(0, 0, FACE_BOTTOM - FRAME / 2, 16, fullW, FRAME, false)
    cube(-(FACE_W / 2 + FRAME / 2), 0, faceMid, 16, FRAME, FACE_H, false)
    cube(FACE_W / 2 + FRAME / 2, 0, faceMid, 16, FRAME, FACE_H, false)
    cube(0, 4, FACE_BOTTOM + FACE_H + FRAME + 6, 34, fullW + 30, 12, true)

    local faceRot, scale = faceRotationAndScale(fx, fy)
    local face, comp = spawnMesh("/Engine/BasicShapes/Plane.Plane", at(0, 0.6, faceMid), faceRot, scale)
    applyFaceMaterial(comp)
    attach(face)
    return parts
end

local function destroyParts(parts)
    for _, a in ipairs(parts or {}) do
        if valid(a) then pcall(function() a:K2_DestroyActor() end) end
    end
end

--------------------------------------------------------------------------------
-- Build menu entry
--------------------------------------------------------------------------------

-- UE4SS can't add DataTable rows on this engine, so the mod borrows a row the game ships
-- disabled (an old duplicate of Hanging Lanterns) and turns it into the sign. The sign itself
-- is a Flag decoration (no styles to pick, small footprint) that the mod hides and dresses as
-- a board. The tile borrows the Trail Markers signpost icon.
local ROW = "HangingLanterns"
local BASE_ROW = "Flags"          -- object the sign is built on
local ICON_ROW = "TrailMarkers"   -- tile icon
local SIGN_NAME = "Trail Map Sign"
local SIGN_COST = 950
local SIGN_DESC = "A big wooden trail map board for guests to check before they drop in. " ..
    "It shows your trails and lifts. After changing trails, press Ctrl+Alt+Y to redraw it."

local rowOriginal               -- snapshot so the row can be put back when the mod turns off
local rowReady = false

local function economyTable()
    local dock = cachedFind("BuildDockComponent")
    if valid(dock) and valid(dock.BuildingEconomyTable) then return dock.BuildingEconomyTable end
    local dt = StaticFindObject("/Game/Data/DT_BuildingEconomy.DT_BuildingEconomy")
    return valid(dt) and dt or nil
end

local function setupRow()
    local dt = economyTable()
    if not dt then return false end
    local row, base, icon = dt:FindRow(ROW), dt:FindRow(BASE_ROW), dt:FindRow(ICON_ROW)
    if not row or not base then log("Build menu rows not found; the sign can't be added to Build"); return true end
    if not rowOriginal then
        -- Only take the row if it is still the game's unused duplicate. If an update ever puts
        -- it back into use, leave it alone rather than replace a real item.
        local current = textOf(row.DisplayName)
        if row.bEnabled == true or (current ~= "Hanging Lanterns" and current ~= SIGN_NAME) then
            log("The borrowed build row is in use by the game now (" .. current ..
                "); Trail Map Sign won't appear in Build. Existing signs still work.")
            return true
        end
        rowOriginal = {
            name = textOf(row.DisplayName), desc = textOf(row.Description), cost = row.BuildCost,
            sort = row.SortOrder, enabled = row.bEnabled, soon = row.bComingSoon,
            rep = row.RequiredReputationLevel, caps = row.AuthoredCapabilities,
            emoji = textOf(row.Emoji),
        }
    end
    row.DisplayName = FText(SIGN_NAME)
    row.Description = FText(SIGN_DESC)
    row.BuildCost = SIGN_COST
    row.bComingSoon = false
    row.RequiredReputationLevel = 0
    row.AuthoredCapabilities = base.AuthoredCapabilities
    row.BlueprintClass = base.BlueprintClass
    if icon then
        row.SortOrder = icon.SortOrder -- sits beside Trail Markers
        pcall(function() row.Emoji = FText(textOf(icon.Emoji)) end)
    end
    row.bEnabled = true
    log("Added " .. SIGN_NAME .. " to Build > Decorations")
    return true
end

local function restoreRow()
    if not rowOriginal then return end
    pcall(function()
        local row = economyTable():FindRow(ROW)
        row.DisplayName = FText(rowOriginal.name)
        row.Description = FText(rowOriginal.desc)
        row.BuildCost = rowOriginal.cost
        row.SortOrder = rowOriginal.sort
        row.bComingSoon = rowOriginal.soon
        row.RequiredReputationLevel = rowOriginal.rep
        row.AuthoredCapabilities = rowOriginal.caps
        pcall(function() row.Emoji = FText(rowOriginal.emoji) end)
        row.bEnabled = rowOriginal.enabled
    end)
    rowReady = false
end

--------------------------------------------------------------------------------
-- Tracking signs
--------------------------------------------------------------------------------

local dressed = {}        -- address -> { base = actor, parts = {...}, preview = bool }
local armed = false       -- the player picked Trail Map Sign in Build and is placing it
local previewGoneTicks = 0
local newBases = {}       -- freshly constructed base actors waiting one tick for their data

local function isSignName(actor)
    local found = false
    pcall(function() if textOf(actor.PlaceableComponent.DisplayName) == SIGN_NAME then found = true end end)
    if not found then pcall(function() if textOf(actor.InstanceName) == SIGN_NAME then found = true end end) end
    return found
end

local function nameAsSign(actor)
    local t = FText(SIGN_NAME)
    pcall(function() actor.PlaceableComponent.DisplayName = t end)
    pcall(function() actor:SetInstanceName(t) end)
    pcall(function() actor.DisplayName = t end)
end

-- The game works out a building's row from its class, which would call the sign a Flag in
-- its info panel. Point it at the sign's row instead (redone after every load).
local function useSignRow(actor)
    pcall(function() actor.EconomyRowName = name(ROW) end)
    -- Refunds use the object's own cost, which would otherwise be the Flag's.
    pcall(function() actor.BaseCost = SIGN_COST end)
    pcall(function() actor.PlaceableComponent.ConstructionCost = SIGN_COST end)
end

local meshClass

-- Hide (or show) the base decoration itself. The game re-shows its placement preview while
-- tinting it, so for previews this is re-applied every tick.
local function unwrap(v)
    if valid(v) then return v end
    local ok, g = pcall(function() return v:get() end)
    if ok and valid(g) then return g end
end

-- The base's visible meshes: its main mesh, the meshes the game tints during placement, and
-- any other static mesh components.
local function baseMeshes(actor)
    local list, seen = {}, {}
    local function add(c)
        c = unwrap(c)
        if c then
            local key = c:GetAddress()
            if not seen[key] then seen[key] = true; list[#list + 1] = c end
        end
    end
    pcall(function() add(actor.MeshComponent) end)
    pcall(function()
        local arr = actor.CachedMaterialComponents
        for i = 1, arr:GetArrayNum() do add(arr[i]) end
    end)
    pcall(function()
        if not valid(meshClass) then meshClass = StaticFindObject("/Script/Engine.StaticMeshComponent") end
        local arr = actor:K2_GetComponentsByClass(meshClass)
        if type(arr) == "table" then
            for _, c in ipairs(arr) do add(c) end
        else
            for i = 1, arr:GetArrayNum() do add(arr[i]) end
        end
    end)
    return list
end

local function hideBase(actor, hidden)
    pcall(function() actor:SetActorHiddenInGame(hidden) end)
    for _, comp in ipairs(baseMeshes(actor)) do
        pcall(function() comp:SetHiddenInGame(hidden, false) end)
        pcall(function() if comp:IsVisible() == hidden then comp:SetVisibility(not hidden, false) end end)
    end
end

-- The board parts are separate actors the game can't select. Give the hidden base an invisible
-- box the size of the board, with the same collision as its own mesh, so clicking anywhere on
-- the board selects the sign for moving, bulldozing or its info panel.
local function addClickBox(actor)
    local boxClass = StaticFindObject("/Script/Engine.BoxComponent")
    if not valid(boxClass) then return nil end
    local top = FACE_BOTTOM + FACE_H + FRAME + 20
    local box
    local ok, err = pcall(function()
        box = actor:AddComponentByClass(boxClass, false, {
            Translation = { X = -5, Y = 0, Z = top / 2 },
            Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
            Scale3D = { X = 1, Y = 1, Z = 1 },
        }, false)
        box = unwrap(box)
        box:SetBoxExtent(vec(22, (FACE_W + 2 * FRAME) / 2, top / 2), false)
        local profile
        for _, m in ipairs(baseMeshes(actor)) do
            if m:GetAddress() ~= box:GetAddress() then profile = m:GetCollisionProfileName(); break end
        end
        if profile then box:SetCollisionProfileName(profile, false) end
        box:SetGenerateOverlapEvents(false)
    end)
    if not ok then log("Could not make the board clickable: " .. tostring(err)); return nil end
    return box
end

local function dress(actor, isPreview)
    local key = actor:GetAddress()
    if dressed[key] and valid(dressed[key].base) then return end
    if not mapDrawn then
        local ok, err = pcall(refreshMap)
        if not ok then log("Map drawing failed, the board will be blank: " .. tostring(err)) end
    end
    local ok, parts = pcall(buildSign, actor)
    if not ok then log("Could not build the sign: " .. tostring(parts)); return end
    hideBase(actor, true)
    local clickBox
    if not isPreview then
        useSignRow(actor)
        clickBox = addClickBox(actor)
    end
    dressed[key] = { base = actor, parts = parts, preview = isPreview, clickBox = clickBox }
end

local function undress(key)
    local d = dressed[key]
    if not d then return end
    destroyParts(d.parts)
    if valid(d.clickBox) then pcall(function() d.clickBox:K2_DestroyComponent(d.clickBox) end) end
    if valid(d.base) then hideBase(d.base, false) end
    dressed[key] = nil
end

local function undressAll()
    for key in pairs(dressed) do undress(key) end
end

-- The class the build menu actually spawns for the sign, learned from the placement preview.
local baseClass

local function classOf(actor)
    local ok, path = pcall(function() return actor:GetClass():GetFullName() end)
    return ok and path or nil
end

local function isBase(actor)
    return baseClass ~= nil and classOf(actor) == baseClass
end

-- Signs loaded from a save are buildings named "Trail Map Sign". FindAllOf walks every object in
-- the game, so this only runs a few times after a resort loads (or the mod is switched back on);
-- new signs are claimed by the placement hook instead. Each building is only checked once.
local notSigns = {}
local SCAN_AT = { 10, 30, 60, 100, 200, 300 }   -- ticks (100 ms) after a load
local ticksSinceLoad, nextScan = 0, 1

local function restartScans()
    ticksSinceLoad, nextScan = 0, 1
end

local function scanForSigns()
    for _, a in ipairs(FindAllOf("BuildingActor") or {}) do
        if valid(a) and a.bIsPreview ~= true then
            local key = a:GetAddress()
            if not dressed[key] and not notSigns[key] then
                if isSignName(a) then dress(a, false) else notSigns[key] = true end
            end
        end
    end
end

local function updatePreview()
    local manager = cachedFind("PlacementManagerComponent")
    local preview = manager and manager.BuildingPreviewActor or nil
    if not valid(preview) then preview = nil end

    if preview then previewGoneTicks = 0 else previewGoneTicks = previewGoneTicks + 1 end
    if armed and previewGoneTicks > 10 then armed = false end -- placement mode ended

    -- Drop dressing from previews that are gone or no longer ours.
    for key, d in pairs(dressed) do
        if d.preview and (not valid(d.base) or not armed or d.base ~= preview) then undress(key) end
    end
    if armed and preview and preview.bIsPreview == true then
        baseClass = classOf(preview)
        dress(preview, true)
        hideBase(preview, true)
    end
end

local function claimNewBases()
    if #newBases == 0 then return end
    local list = newBases
    newBases = {}
    for _, entry in ipairs(list) do
        local a = entry.actor
        entry.tries = (entry.tries or 0) + 1
        if valid(a) and a.bIsPreview == true and entry.tries < 4 then
            newBases[#newBases + 1] = entry -- may still be finishing placement; look again
        elseif valid(a) and a.bIsPreview ~= true and not dressed[a:GetAddress()] then
            if entry.armed and armed then
                nameAsSign(a)
                dress(a, false)
                log("Placed a " .. SIGN_NAME)
            elseif isSignName(a) then
                dress(a, false)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Build palette preview
--------------------------------------------------------------------------------

-- The palette's detail panel would show a plain flag, so while Trail Map Sign is selected it
-- shows a picture of the sign instead: the trail map inset in a wooden frame.
local PREVIEW_SIZE = 1024
local previewTarget
local previewDrawn = false
local swappedImage, savedBrushResource

local function drawPreviewImage()
    if not valid(mapTarget) or not mapDrawn then return end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if not valid(previewTarget) then
        previewTarget = krl:CreateRenderTarget2D(UEHelpers.GetWorld(), PREVIEW_SIZE, PREVIEW_SIZE, 3,
            color(0, 0, 0, 1), false, false)
        if not valid(previewTarget) then return end
    end
    Draw.begin(previewTarget)
    local ok, err = pcall(function()
        local S = PREVIEW_SIZE
        Draw.rect(0, 0, S, S, srgb(0.16, 0.20, 0.25))              -- backdrop like the game's
        local frame = 26
        local w = S * 0.92
        local h = w * RT_H / RT_W
        local x, y = (S - w) / 2, (S - h) / 2
        Draw.rect(x - frame, y - frame, w + frame * 2, h + frame * 2, srgb(0.30, 0.19, 0.09))
        Draw.rect(x - 6, y - 6, w + 12, h + 12, srgb(0.14, 0.08, 0.04))
        Draw.canvas:K2_DrawTexture(mapTarget, v2(x, y), v2(w, h), v2(0, 0), v2(1, 1),
            color(1, 1, 1, 1), 0, 0, v2(0.5, 0.5))
    end)
    Draw.finish()
    if not ok then log("Preview picture failed: " .. tostring(err)) else previewDrawn = true end
end

local function restorePalettePreview()
    if swappedImage and valid(swappedImage) and savedBrushResource ~= nil then
        pcall(function() swappedImage:SetBrushResourceObject(savedBrushResource) end)
    end
    swappedImage, savedBrushResource = nil, nil
end

local function updatePalettePreview()
    local dock = cachedFind("BuildDockComponent")
    local palette = dock and dock.BuildPaletteWidget or nil
    local visible = false
    if valid(palette) then pcall(function() visible = palette:IsPaletteVisible() == true end) end
    if not visible then
        if swappedImage then restorePalettePreview() end
        return
    end
    local panel = palette.DetailPanel
    if not valid(panel) then return end
    local shown = ""
    pcall(function() shown = panel.NameLabel:GetText():ToString() end)
    local image = panel.PreviewImage
    if shown == SIGN_NAME and valid(image) then
        if not mapDrawn then pcall(refreshMap) end
        if not previewDrawn or not valid(previewTarget) then drawPreviewImage() end
        if not valid(previewTarget) then return end
        local current
        pcall(function() current = image.Brush.ResourceObject end)
        if not (valid(current) and current:GetAddress() == previewTarget:GetAddress()) then
            if swappedImage == nil then
                swappedImage, savedBrushResource = image, current
            end
            pcall(function() image:SetBrushResourceObject(previewTarget) end)
        end
    elseif swappedImage then
        restorePalettePreview()
    end
end

-- A bulldozed sign's base can linger in memory until the next garbage collection, so also watch
-- the game's list of placed buildings: once a sign has been listed, dropping off the list means
-- it was removed.
-- Reading the whole list is only needed when its length changes (something was built or
-- bulldozed) or a new sign hasn't shown up on it yet; otherwise this is one property read.
local registryCount

local function registeredBuildings(arr)
    local set = {}
    for i = 1, arr:GetArrayNum() do
        local b = arr[i]
        if valid(b) then set[b:GetAddress()] = true end
    end
    return set
end

local function cleanUp()
    local placed, waiting = false, false
    for _, d in pairs(dressed) do
        if not d.preview then
            placed = true
            -- Give a new sign a few checks to appear on the list, then stop rebuilding for it.
            if not d.registered then
                d.checks = (d.checks or 0) + 1
                if d.checks <= 10 then waiting = true end
            end
        end
    end
    local listed
    if placed then
        pcall(function()
            local arr = cachedFind("PlaceableRegistrySubsystem").Buildings
            local count = arr:GetArrayNum()
            if count ~= registryCount or waiting then
                registryCount = count
                listed = registeredBuildings(arr)
            end
        end)
    end
    for key, d in pairs(dressed) do
        local gone = not valid(d.base)
        if not gone and listed and not d.preview then
            if listed[key] then
                d.registered = true
            elseif d.registered then
                gone = true
            end
        end
        if gone then
            destroyParts(d.parts)
            dressed[key] = nil
            if not d.preview then log("Removed a bulldozed " .. SIGN_NAME) end
        end
    end
end

--------------------------------------------------------------------------------
-- Actions and keybinds
--------------------------------------------------------------------------------

local function modActive() return ModRef:GetSharedVariable(liveKey) ~= false end

local function refreshAction()
    refreshMap()
    previewDrawn = false
    log("Trail maps refreshed")
end

local actions = {
    ["Refresh trail maps"] = refreshAction,
}

local function run(actionName)
    if not modActive() or ModRef:GetSharedVariable(menuOpenKey) then return end
    local ok, err = pcall(actions[actionName])
    if not ok then log(actionName .. " failed: " .. tostring(err)) end
end

-- The game ignores modifiers, so the fallback uses a letter it has no binding for.
local fallbackKeys = {
    ["Refresh trail maps"] = Key.Y,
}

local function managedKey(action) return "SkiEOMods.keybind.managed." .. MOD .. "." .. action end
local function requestKey(action) return "SkiEOMods.keybind.request." .. MOD .. "." .. action end

if type(LoopInGameThreadWithDelay) ~= "function" then
    log("UE4SS with game-thread scheduling is required")
    return
end

ModRef:SetSharedVariable(liveKey, true)
for action in pairs(actions) do ModRef:SetSharedVariable(requestKey(action), nil) end

-- Unloading happens as the game shuts down, possibly off the game thread, so don't touch game
-- objects here (turning the mod off from the Mods menu is handled safely in the loop below).
ModRef.OnUnload = function()
    for action in pairs(actions) do ModRef:SetSharedVariable(requestKey(action), nil) end
    ModRef:SetSharedVariable(liveKey, nil)
end

for action, key in pairs(fallbackKeys) do
    RegisterKeyBind(key, { ModifierKey.CONTROL, ModifierKey.ALT }, function()
        ExecuteInGameThread(function()
            if not ModRef:GetSharedVariable(managedKey(action)) then run(action) end
        end)
    end)
end

local hooked = pcall(function()
    RegisterHook("/Script/SkiResortSimulator.BuildDockComponent:OnPaletteItemSelected",
        function(_, _, rowName)
            local r = ""
            pcall(function() r = rowName:get():ToString() end)
            armed = modActive() and r == ROW
            previewGoneTicks = 0
        end)
end)
if not hooked then log("Could not watch the Build menu; placing signs from Build won't work") end

pcall(function()
    NotifyOnNewObject("/Script/SkiResortSimulator.PlaceableActor", function(obj)
        if armed and isBase(obj) then
            newBases[#newBases + 1] = { actor = obj, armed = armed }
            -- Claim a just-placed sign on the next frame instead of the next 100 ms tick, so the
            -- base decoration doesn't flash into view.
            if armed then
                ExecuteInGameThread(function()
                    local ok, err = pcall(claimNewBases)
                    if not ok then log("Claim failed: " .. tostring(err)) end
                end)
            end
        end
    end)
end)

RegisterLoadMapPreHook(function()
    -- The old world's actors and image go away with the level.
    dressed, newBases, notSigns = {}, {}, {}
    armed = false
    lookups = {}
    restartScans()
    registryCount = nil
    mapTarget, mapDrawn = nil, false
    previewTarget, previewDrawn = nil, false
    swappedImage, savedBrushResource = nil, nil
    woodMaterial, darkWoodMaterial = nil, nil
    cachedResortName = nil
end)

LoopInGameThreadWithDelay(100, function()
    tickCount = tickCount + 1
    local active = modActive()
    if active ~= lastModState then
        lastModState = active
        if active then
            rowReady = false
            notSigns = {}
            restartScans()
        else
            armed = false
            pcall(restorePalettePreview)
            pcall(undressAll)
            pcall(restoreRow)
        end
        log(active and "Turned on from Mods menu" or "Turned off from Mods menu")
    end
    if not active then return end

    if not rowReady then
        local ok, done = pcall(setupRow)
        if not ok then log("Build menu setup failed: " .. tostring(done)); rowReady = true
        elseif done then rowReady = true end
    end

    for action in pairs(actions) do
        if ModRef:GetSharedVariable(requestKey(action)) then
            ModRef:SetSharedVariable(requestKey(action), nil)
            run(action)
        end
    end

    local ok, err = pcall(function()
        claimNewBases()
        updatePreview()
        updatePalettePreview()
        ticksSinceLoad = ticksSinceLoad + 1
        if SCAN_AT[nextScan] and ticksSinceLoad >= SCAN_AT[nextScan] then
            nextScan = nextScan + 1
            scanForSigns()
        end
        if tickCount % 5 == 0 then cleanUp() end
    end)
    if not ok then log("Update failed: " .. tostring(err)) end
end)

log("Loaded. Build > Decorations > " .. SIGN_NAME .. ". Ctrl+Alt+Y redraws the maps.")
