-- tools/capture.lua
-- Screenshot and video capture via CaptureService.
-- Note: CaptureService:CaptureScreenshot returns rbxtemp:// content IDs
-- which are in-memory only and cannot be exported as raw bytes from Luau.
-- The Rust server uses OS-level screenshot as a fallback for actual files on disk.

local Capture = {}

-- Feature-detect CaptureService
local function getCaptureService()
	local ok, svc = pcall(function()
		return game:GetService("CaptureService")
	end)
	if ok and svc then
		return svc
	end
	return nil
end

function Capture.screenshot(args, ctx)
	local captureService = getCaptureService()

	local tag = args.tag
	local contentId = nil
	local captureComplete = false
	local captureError = nil

	if captureService and captureService.CaptureScreenshot then
		local ok, err = pcall(function()
			captureService:CaptureScreenshot(function(id)
				contentId = id
				captureComplete = true
			end)
		end)

		if not ok then
			captureError = "CaptureScreenshot failed: " .. tostring(err)
		else
			-- Wait for callback with timeout
			local elapsed = 0
			while not captureComplete and elapsed < 5 do
				task.wait(0.1)
				elapsed = elapsed + 0.1
			end

			if not captureComplete then
				captureError = "Screenshot capture timed out after 5 seconds"
			end
		end
	else
		captureError = "CaptureService not available in this Studio context"
	end

	-- Push capture event to bridge for Rust-side OS screenshot
	if ctx and ctx.bridge then
		ctx.bridge:pushEvent("studio.capture", {
			kind = "screenshot",
			tag = tag,
			contentId = contentId,
			success = captureComplete,
			error = captureError,
		})
	end

	if captureComplete then
		print("[MCP] Screenshot captured: " .. tostring(contentId))
		return true, {
			ok = true,
			captureId = contentId,
			note = "In-engine capture saved as rbxtemp:// content. "
				.. "The Rust server also takes an OS-level screenshot saved to the capture folder on disk. "
				.. "Check .roblox-captures/index.json for the file path.",
			tag = tag,
		}
	else
		-- Even if CaptureService fails, the Rust server's OS screenshot may succeed
		return true, {
			ok = true,
			captureId = nil,
			note = (captureError or "CaptureService unavailable")
				.. ". The Rust server will attempt an OS-level screenshot as fallback. "
				.. "Check .roblox-captures/index.json for the file path.",
			tag = tag,
		}
	end
end

function Capture.videoStart(args, _ctx)
	-- CaptureService does not expose video recording control via Luau API.
	return false, "Video recording is not supported via the CaptureService Luau API. "
		.. "Use Roblox Studio's built-in recording (View > Record Video) or OS-level screen recording tools. "
		.. "The studio.capture_screenshot tool is available for still images."
end

function Capture.videoStop(args, _ctx)
	return false, "Video recording is not supported via the CaptureService Luau API. "
		.. "See studio.capture_video_start for alternatives."
end

return Capture
