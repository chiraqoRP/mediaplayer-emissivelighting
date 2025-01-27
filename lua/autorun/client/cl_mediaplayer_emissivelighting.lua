local defaultConfig = {
	offset = Vector(0, 0, 0),   -- translation from entity origin
	angle = Angle(0, 90, 90),   -- rotation
	width = 64,                 -- screen width
	height = 64 * (9 / 16)      -- screen height
}

local function GetScreenAABB(ent, pos, ang)
    if !pos then
        local _, _, sPos, sAng = ent:GetMediaPlayerPosition()

        pos, ang = sPos, sAng
    end

    local cfg = ent.PlayerConfig or defaultConfig

    local bottomDist, rightDist = cfg.height * 1, cfg.width * 1
    local mins, maxes = pos, ang:Forward() * rightDist

    maxes:Add(ang:Right() * bottomDist)
    maxes:Add(pos)

    return mins, maxes
end

local function GetScreenCenter(ent, pos, ang)
    local mins, maxes = GetScreenAABB(ent, pos, ang)
    local center = Vector()

    center:Add(mins)
    center:Add(maxes)
    center:Div(2)

    return center
end

local function GetScreenPos(ent)
    if !ent._mp then
        return
    end

    local w, h, pos, ang = ent:GetMediaPlayerPosition()
    local direction = ang:Up()

    return GetScreenCenter(ent, pos, ang), direction:Angle(), w > h and w or h
end

local curPlayer = nil
local curProjTexture = nil
local rW, rH = 128, 128
local blurRT = GetRenderTargetEx("MediaPlayer_EmissiveLighting", rW, rH, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, 2, 0, IMAGE_FORMAT_RGB888)

local function UpdateScreen(playerEnt)
    local mediaPlayer = playerEnt._mp

    render.PushRenderTarget(blurRT)

    cam.Start2D()
        surface.SetDrawColor(0, 0, 0, 255)
        surface.DrawRect(0, 0, rW, rH)

        -- Since theres a delay to projected textures being removed, we clear the RT so the lighting disappears immediately.
        if !IsValid(mediaPlayer) then
            cam.End2D()
            render.PopRenderTarget()

            return
        end

        local media = mediaPlayer:GetMedia()

        if media and media.Base == "browser" then
            local browser = media:GetBrowser()

            -- Draw browser mat, if there is one.
            if browser then
                local material = browser:GetHTMLMaterial()
                local w, h = browser:GetSize()

                -- HTML materials are always 2048x1024, so we have to increase our rect's size to scale proportionally.
                local wMul, hMul = 2048 / w, 1024 / h

                if material and !material:IsError() then
                    -- Width is different depending on video resolution, this calculates the proper U offset to stop tiling.
                    local uOffset = rW - (rW * wMul)

                    surface.SetDrawColor(255, 255, 255, 255)
                    surface.SetMaterial(material)

                    -- Draw flipped.
                    surface.DrawTexturedRectUV(0 + uOffset, 0, rW * wMul, rH * hMul, 1, 0, 0, 1)
                end
            end
        end
    cam.End2D()

    -- Try to stop the blur from darkening the RT.
    surface.SetDrawColor(255, 255, 255, 0)

    -- Blur the RT for uniform lighting.
    render.BlurRenderTarget(blurRT, rW / 4, rH / 4, 8)
    render.PopRenderTarget()
end

local enabled = CreateClientConVar("mediaplayer_lighting", 1, true, false, "Enables emissive lighting for media players.", 0, 1)

hook.Add("PostDrawEffects", "MediaPlayer_EmissiveLighting.UpdateRT", function()
    if !enabled:GetBool() or !MediaPlayer or !IsValid(curPlayer) or !curProjTexture or !curProjTexture:IsValid() then
        return
    end

    -- Update render target.
    UpdateScreen(curPlayer)
end)

local function UpdateProjectedTexture(projTexture, pos, ang, scale)
    -- If missing pos then just delete.
    if !pos then
        projTexture:Remove()

        return
    end

    projTexture:SetPos(pos)
    projTexture:SetAngles(ang)
    projTexture:Update()
end

-- This updates our RT and also sets up our projected textures.
hook.Add("PreDrawOpaqueRenderables", "MediaPlayer_EmissiveLighting.UpdateProjTexture", function(isDrawingDepth, isDrawSkybox, isDraw3DSkybox)
    if isDrawingDepth or isDrawSkybox or isDraw3DSkybox then
        return
    end

    if !enabled:GetBool() or !MediaPlayer or !IsValid(curPlayer) or !curProjTexture or !curProjTexture:IsValid() then
        return
    end

    UpdateProjectedTexture(curProjTexture, GetScreenPos(curPlayer))
end)

local shadows = CreateClientConVar("mediaplayer_lighting_shadows", 0, true, false, "Makes media players cast shadows. Very expensive, should be kept disabled on servers with lots of players.", 0, 1)

local function AddProjection(ent)
    if !IsValid(ent) then
        return
    end

    local pos, ang, scale = GetScreenPos(ent)

    -- If it fails to find a screen pos, stop function
    if !pos then
        return
    end

    local projTexture = ProjectedTexture()
    projTexture:SetTexture(blurRT)
    projTexture:SetBrightness(1.75)
    projTexture:SetEnableShadows(shadows:GetBool())
    projTexture:SetFarZ(scale * 4)
    projTexture:SetNearZ(32)
    projTexture:SetFOV(135)
    projTexture:SetQuadraticAttenuation(1)
    projTexture:SetLinearAttenuation(0.2)
    projTexture:SetConstantAttenuation(0.10)

    UpdateProjectedTexture(projTexture, pos, ang, scale)

    return projTexture
end

local pixVisHandle = util.GetPixelVisibleHandle()
local sScale = 0

local function IsHidden(ent)
    if ent:IsDormant() then
        return true
    end

    -- Pixvis will return 0 when we're in its bounds, but if we're in it's bounds, its almost certainly is lighting our scene.
    local farZ = sScale * 4
    local pos = ent:GetPos()

    if LocalPlayer():GetPos():DistToSqr(pos) < (farZ * 1.2) ^ 2 then
        return false
    end

    -- Otherwise, use PixelVisible.
    local pixVis = util.PixelVisible(pos, farZ, pixVisHandle)

    if pixVis == 0 then
        return true
    end

    return false
end

hook.Add("Think", "MediaPlayer_EmissiveLighting.Occlusion", function()
    if !enabled:GetBool() or !IsValid(curPlayer) then
        return
    end

    local isHidden = IsHidden(curPlayer)
    local isProjValid = curProjTexture and curProjTexture:IsValid()

    if isHidden and isProjValid then
        curProjTexture:Remove()
        curProjTexture = nil
    elseif !isHidden and !isProjValid then
        curProjTexture = AddProjection(curPlayer)
    end
end)

timer.Create("MediaPlayer_EmissiveLighting.DeleteEntReference", 0.5, 0, function()
    if !enabled:GetBool() or (IsValid(curPlayer) and curPlayer._mp) then
        return
    end

    if curProjTexture and curProjTexture:IsValid() then
        curProjTexture:Remove()
        curProjTexture = nil
    end

    curPlayer = nil
end)

hook.Add("OnMediaPlayerUpdate", "MediaPlayer_EmissiveLighting", function(mediaPlayer)
    if !enabled:GetBool() then
        return
    end

    local ent = mediaPlayer.Entity

    if !IsValid(ent) then
        return
    end

    curPlayer = ent

    local _, _, scale = GetScreenPos(ent)

    sScale = scale
end)

-- local blurMat = CreateMaterial("MediaPlayer_EmissiveLighting_BlurMat", "UnlitGeneric", {
--     ["$basetexture"] = "MediaPlayer_EmissiveLighting",
--     ["$translucent"] = 1,
--     ["$vertexcolor"] = 1
-- })

-- local developer = GetConVar("developer")
-- local rtFormat = "%s (%i, %i):"

-- hook.Add("HUDPaint", "MediaPlayer_EmissiveLightingg_DrawDebug", function()
--     if developer:GetInt() == 0 then
--         return
--     end

--     surface.SetFont("DermaDefault")
--     surface.SetTextColor(255, 255, 255, 255)
--     surface.SetTextPos(512, 492)
--     surface.DrawText(string.format(rtFormat, "rt", rW, rH))

--     surface.SetDrawColor(255, 255, 255, 255)
--     surface.SetMaterial(blurMat)
--     surface.DrawTexturedRect(512, 512, rW, rH)
-- end)