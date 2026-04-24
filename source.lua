	-- GangstaGlitchMenu v2.2
	-- Maintainer notes:
	-- 1) Keep feature toggles idempotent: repeated enable/disable calls must be safe.
	-- 2) Prefer event-driven hooks over per-frame full scans for performance.
	-- 3) When editing UI controls, keep text labels and handler names aligned.
	-- 4) Keep cleanup paths complete; every connection created should be disconnected.

	local Players = game:GetService("Players")
	local TextService = game:GetService("TextService")
	local TweenService = game:GetService("TweenService")
	local UserInputService = game:GetService("UserInputService")
	local ContextActionService = game:GetService("ContextActionService")
	local TeleportService = game:GetService("TeleportService")
	local RunService = game:GetService("RunService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local HttpService = game:GetService("HttpService")
	local ArsenalData = ReplicatedStorage:FindFirstChild("Arsenal") and ReplicatedStorage.Arsenal:FindFirstChild("Data")
	local weaponDataCache = {}
	local aimDraw = {}
	local MENU_VERSION = "2.2.0"
	local REMOTE_MENU_URL = "https://raw.githubusercontent.com/NeusenceTheDev/menu.lua/refs/heads/main/menu.lua"
	local UPDATE_TEMP_SUFFIX = ".codex-update.tmp"
	local UPDATE_BACKUP_SUFFIX = ".codex-update.bak"

	local function isCharacterAlive(character)
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		return hum and hum.Health > 0
	end

	-- =============== ERROR LOGGING AND DIAGNOSTICS ===============
	local errorLog = {}
	local commandLog = {}
	local MAX_LOG_ENTRIES = 100
	local LOG_EXTERNAL_SCRIPT_ERRORS = false
	local thisScript = script

	local function logError(category, message, stackTrace, additionalData)
		local timestamp = os.date("%H:%M:%S")
		local errorEntry = {
			timestamp = timestamp,
			category = category,
			message = message,
			stackTrace = stackTrace or debug.traceback(),
			additionalData = additionalData,
			robloxVersion = version() or "Unknown"
		}

		table.insert(errorLog, 1, errorEntry) -- Insert at beginning for newest first
		if #errorLog > MAX_LOG_ENTRIES then
			table.remove(errorLog) -- Remove oldest
		end

		-- Enhanced console output with color coding
		local prefix = string.format("[ERROR][%s][%s] ", timestamp, category)
		warn(prefix .. message)
		if stackTrace then
			warn("Stack Trace: " .. stackTrace)
		end
		if additionalData then
			warn("Additional Data: " .. tostring(additionalData))
		end
	end

	local function logCommand(command, success, result, executionTime)
		local timestamp = os.date("%H:%M:%S")
		local commandEntry = {
			timestamp = timestamp,
			command = command,
			success = success,
			result = result,
			executionTime = executionTime or 0,
			player = Players.LocalPlayer and Players.LocalPlayer.Name or "Unknown"
		}

		table.insert(commandLog, 1, commandEntry)
		if #commandLog > MAX_LOG_ENTRIES then
			table.remove(commandLog)
		end

		local status = success and "[SUCCESS]" or "[FAILED]"
		print(string.format("[CMD][%s]%s %s (%.3fs)", timestamp, status, command, executionTime or 0))
		if not success and result then
			warn("Command Error: " .. tostring(result))
		end
	end

	local function safeExecute(func, category, ...)
		local startTime = tick()
		local success, result = pcall(func, ...)
		local executionTime = tick() - startTime

		if not success then
			logError(category, "Execution failed: " .. tostring(result), debug.traceback(), {...})
			return false, result
		end

		logCommand(category, true, result, executionTime)
		return true, result
	end

	local function validateArguments(funcName, args, expectedTypes)
		for i, expectedType in ipairs(expectedTypes) do
			local arg = args[i]
			local argType = type(arg)
			if argType ~= expectedType then
				logError("VALIDATION", string.format("Function %s: Argument %d expected %s, got %s", funcName, i, expectedType, argType), nil, {args = args})
				return false
			end
		end
		return true
	end

	local function getErrorReport()
		local report = "=== ERROR REPORT ===\n"
		report = report .. string.format("Total Errors: %d\n\n", #errorLog)

		for i, error in ipairs(errorLog) do
			report = report .. string.format("[%d] %s [%s] %s\n", i, error.timestamp, error.category, error.message)
			if error.additionalData then
				report = report .. string.format("    Data: %s\n", tostring(error.additionalData))
			end
			report = report .. "\n"
		end

		return report
	end

	local function getCommandReport()
		local report = "=== COMMAND LOG ===\n"
		report = report .. string.format("Total Commands: %d\n\n", #commandLog)

		for i, cmd in ipairs(commandLog) do
			local status = cmd.success and "SUCCESS" or "FAILED"
			report = report .. string.format("[%d] %s [%s] %s (%.3fs)\n", i, cmd.timestamp, status, cmd.command, cmd.executionTime)
			if not cmd.success and cmd.result then
				report = report .. string.format("    Error: %s\n", tostring(cmd.result))
			end
			report = report .. "\n"
		end

		return report
	end

	local function getDetailedScriptOutput()
		local report = "=== SCRIPT OUTPUT ===\n"
		report = report .. string.format("Generated: %s\n", os.date("%Y-%m-%d %H:%M:%S"))
		report = report .. string.format("Player: %s\n", Players.LocalPlayer and Players.LocalPlayer.Name or "Unknown")
		report = report .. string.format("Version: %s\n\n", version() or "Unknown")
		report = report .. getErrorReport()
		report = report .. "\n"
		report = report .. getCommandReport()
		return report
	end

	local function normalizeVersion(versionString)
		local parts = {}
		for chunk in tostring(versionString or ""):gmatch("%d+") do
			parts[#parts + 1] = tonumber(chunk) or 0
		end
		return parts
	end

	local function compareVersions(leftVersion, rightVersion)
		local left = normalizeVersion(leftVersion)
		local right = normalizeVersion(rightVersion)
		local maxLength = math.max(#left, #right)

		for i = 1, maxLength do
			local leftPart = left[i] or 0
			local rightPart = right[i] or 0
			if leftPart < rightPart then
				return -1
			elseif leftPart > rightPart then
				return 1
			end
		end

		return 0
	end

	local function extractRemoteVersion(source)
		if type(source) ~= "string" then
			return nil
		end

		return source:match("MENU_VERSION%s*=%s*[\"']([^\"']+)[\"']")
	end

	local updatePopupState = {
		gui = nil,
		frame = nil,
		titleLabel = nil,
		statusLabel = nil,
		progressFill = nil,
		progressLabel = nil,
		interactionEvent = nil,
		choice = nil,
	}

	local function setUpdatePopupStatus(title, statusText, progressText, fillScale)
		if updatePopupState.titleLabel then
			updatePopupState.titleLabel.Text = title or updatePopupState.titleLabel.Text
		end
		if updatePopupState.statusLabel then
			updatePopupState.statusLabel.Text = statusText or updatePopupState.statusLabel.Text
		end
		if updatePopupState.progressLabel then
			updatePopupState.progressLabel.Text = progressText or updatePopupState.progressLabel.Text
		end
		if updatePopupState.progressFill and type(fillScale) == "number" then
			local clamped = math.clamp(fillScale, 0, 1)
			TweenService:Create(updatePopupState.progressFill, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.new(clamped, 0, 1, 0),
			}):Play()
		end
	end

	local function closeUpdatePopup(finalTitle, finalStatus, delaySeconds)
		if updatePopupState.titleLabel or updatePopupState.statusLabel then
			setUpdatePopupStatus(finalTitle, finalStatus, "", 1)
		end

		local gui = updatePopupState.gui
		local frame = updatePopupState.frame
		if not gui or not frame then
			return
		end

		task.delay(delaySeconds or 0.8, function()
			if frame and frame.Parent then
				local tweenOut = TweenService:Create(frame, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					BackgroundTransparency = 1,
					Size = UDim2.new(0, 410, 0, 168),
				})
				tweenOut:Play()
				tweenOut.Completed:Wait()
			end
			if gui and gui.Parent then
				gui:Destroy()
			end
			if updatePopupState.interactionEvent then
				updatePopupState.interactionEvent:Destroy()
			end
			updatePopupState.gui = nil
			updatePopupState.frame = nil
			updatePopupState.titleLabel = nil
			updatePopupState.statusLabel = nil
			updatePopupState.progressFill = nil
			updatePopupState.progressLabel = nil
			updatePopupState.interactionEvent = nil
			updatePopupState.choice = nil
		end)
	end

	local function createUpdatePopup()
		local popupGui = Instance.new("ScreenGui")
		popupGui.Name = "MenuUpdatePopup"
		popupGui.ResetOnSpawn = false
		popupGui.IgnoreGuiInset = true
		popupGui.DisplayOrder = 10050
		popupGui.Parent = game:GetService("CoreGui")

		local backdrop = Instance.new("Frame")
		backdrop.Name = "Backdrop"
		backdrop.Size = UDim2.new(1, 0, 1, 0)
		backdrop.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		backdrop.BackgroundTransparency = 0.42
		backdrop.BorderSizePixel = 0
		backdrop.Parent = popupGui

		local frame = Instance.new("Frame")
		frame.Name = "Card"
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.new(0.5, 0, 0.5, 24)
		frame.Size = UDim2.new(0, 430, 0, 176)
		frame.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
		frame.BackgroundTransparency = 0.02
		frame.BorderSizePixel = 0
		frame.Parent = popupGui

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 14)
		corner.Parent = frame

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 40, 80)
		stroke.Transparency = 0.18
		stroke.Thickness = 1.2
		stroke.Parent = frame

		local gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(20, 20, 28)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(10, 10, 16)),
		})
		gradient.Rotation = 145
		gradient.Parent = frame

		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Position = UDim2.new(0, 16, 0, 14)
		title.Size = UDim2.new(1, -32, 0, 24)
		title.Font = Enum.Font.GothamBold
		title.Text = "Update Ready"
		title.TextColor3 = Color3.fromRGB(240, 240, 245)
		title.TextSize = 18
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = frame

		local status = Instance.new("TextLabel")
		status.BackgroundTransparency = 1
		status.Position = UDim2.new(0, 16, 0, 46)
		status.Size = UDim2.new(1, -32, 0, 56)
		status.Font = Enum.Font.GothamMedium
		status.Text = "Manual confirmation is required before menu.lua contacts GitHub."
		status.TextColor3 = Color3.fromRGB(214, 218, 230)
		status.TextSize = 14
		status.TextWrapped = true
		status.TextXAlignment = Enum.TextXAlignment.Left
		status.TextYAlignment = Enum.TextYAlignment.Top
		status.Parent = frame

		local progressBack = Instance.new("Frame")
		progressBack.BackgroundColor3 = Color3.fromRGB(28, 28, 38)
		progressBack.BorderSizePixel = 0
		progressBack.Position = UDim2.new(0, 16, 0, 112)
		progressBack.Size = UDim2.new(1, -32, 0, 12)
		progressBack.Parent = frame
		local progressCorner = Instance.new("UICorner")
		progressCorner.CornerRadius = UDim.new(1, 0)
		progressCorner.Parent = progressBack

		local progressFill = Instance.new("Frame")
		progressFill.BackgroundColor3 = Color3.fromRGB(255, 78, 112)
		progressFill.BorderSizePixel = 0
		progressFill.Size = UDim2.new(0.08, 0, 1, 0)
		progressFill.Parent = progressBack
		local progressFillCorner = Instance.new("UICorner")
		progressFillCorner.CornerRadius = UDim.new(1, 0)
		progressFillCorner.Parent = progressFill

		local progressLabel = Instance.new("TextLabel")
		progressLabel.BackgroundTransparency = 1
		progressLabel.Position = UDim2.new(0, 16, 0, 130)
		progressLabel.Size = UDim2.new(1, -32, 0, 20)
		progressLabel.Font = Enum.Font.Gotham
		progressLabel.Text = REMOTE_MENU_URL
		progressLabel.TextColor3 = Color3.fromRGB(156, 160, 174)
		progressLabel.TextSize = 12
		progressLabel.TextTruncate = Enum.TextTruncate.AtEnd
		progressLabel.TextXAlignment = Enum.TextXAlignment.Left
		progressLabel.Parent = frame

		local actionRow = Instance.new("Frame")
		actionRow.BackgroundTransparency = 1
		actionRow.Position = UDim2.new(0, 16, 0, 154)
		actionRow.Size = UDim2.new(1, -32, 0, 32)
		actionRow.Parent = frame

		local continueButton = Instance.new("TextButton")
		continueButton.Size = UDim2.new(0.5, -6, 1, 0)
		continueButton.Position = UDim2.new(0, 0, 0, 0)
		continueButton.BackgroundColor3 = Color3.fromRGB(255, 40, 80)
		continueButton.Text = "Continue Update"
		continueButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		continueButton.TextSize = 14
		continueButton.Font = Enum.Font.GothamBold
		continueButton.AutoButtonColor = true
		continueButton.Parent = actionRow
		local continueCorner = Instance.new("UICorner")
		continueCorner.CornerRadius = UDim.new(0, 10)
		continueCorner.Parent = continueButton

		local skipButton = Instance.new("TextButton")
		skipButton.Size = UDim2.new(0.5, -6, 1, 0)
		skipButton.Position = UDim2.new(0.5, 6, 0, 0)
		skipButton.BackgroundColor3 = Color3.fromRGB(26, 26, 36)
		skipButton.Text = "Skip Update"
		skipButton.TextColor3 = Color3.fromRGB(220, 224, 236)
		skipButton.TextSize = 14
		skipButton.Font = Enum.Font.GothamBold
		skipButton.AutoButtonColor = true
		skipButton.Parent = actionRow
		local skipCorner = Instance.new("UICorner")
		skipCorner.CornerRadius = UDim.new(0, 10)
		skipCorner.Parent = skipButton

		local interactionEvent = Instance.new("BindableEvent")
		updatePopupState.interactionEvent = interactionEvent

		continueButton.MouseButton1Click:Connect(function()
			if updatePopupState.choice then
				return
			end
			updatePopupState.choice = "continue"
			continueButton.Active = false
			skipButton.Active = false
			continueButton.Text = "Starting..."
			skipButton.Text = "Please wait"
			interactionEvent:Fire("continue")
		end)

		skipButton.MouseButton1Click:Connect(function()
			if updatePopupState.choice then
				return
			end
			updatePopupState.choice = "skip"
			continueButton.Active = false
			skipButton.Active = false
			continueButton.Text = "Continue Update"
			skipButton.Text = "Skipping..."
			interactionEvent:Fire("skip")
		end)

		updatePopupState.gui = popupGui
		updatePopupState.frame = frame
		updatePopupState.titleLabel = title
		updatePopupState.statusLabel = status
		updatePopupState.progressFill = progressFill
		updatePopupState.progressLabel = progressLabel

		TweenService:Create(frame, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, 0, 0.5, 0),
		}):Play()

		return popupGui
	end

	local function supportsLocalFileUpdates()
		return type(readfile) == "function"
			and type(writefile) == "function"
			and type(isfile) == "function"
			and type(delfile) == "function"
	end

	local function getMenuInstallPath()
		if type(getscriptpath) == "function" then
			local ok, path = pcall(getscriptpath)
			if ok and type(path) == "string" and path ~= "" then
				return path
			end
		end

		return nil
	end

	local function fetchRemoteMenuSource(setStatus)
		local requestFallback = nil
		if type(request) == "function" then
			requestFallback = request
		elseif type(http_request) == "function" then
			requestFallback = http_request
		elseif type(syn) == "table" and type(syn.request) == "function" then
			requestFallback = syn.request
		end

		if type(game.HttpGet) == "function" then
			if setStatus then
				setStatus("Fetching from GitHub", "Requesting " .. REMOTE_MENU_URL .. " via game:HttpGet()", "game:HttpGet", 0.28)
			end
			local ok, body = pcall(function()
				return game:HttpGet(REMOTE_MENU_URL, true)
			end)
			if ok and type(body) == "string" and #body > 0 then
				return true, body
			end
		end

		if requestFallback then
			if setStatus then
				setStatus("Fetching from GitHub", "Requesting " .. REMOTE_MENU_URL .. " via executor HTTP API.", "request/http_request", 0.45)
			end
			local ok, response = pcall(function()
				return requestFallback({
					Url = REMOTE_MENU_URL,
					Method = "GET",
				})
			end)
			if ok and response then
				local body = response.Body or response.body
				if type(body) == "string" and #body > 0 then
					return true, body
				end
			end
		end

		if HttpService and HttpService.GetAsync then
			if setStatus then
				setStatus("Fetching from GitHub", "Requesting " .. REMOTE_MENU_URL .. " via HttpService:GetAsync().", "HttpService:GetAsync", 0.6)
			end
			local ok, body = pcall(function()
				return HttpService:GetAsync(REMOTE_MENU_URL, true)
			end)
			if ok and type(body) == "string" and #body > 0 then
				return true, body
			end
		end

		return false, "No supported HTTP fetch API was available"
	end

	local function attemptMenuAutoUpdate(setStatus)
		if setStatus then
			setStatus("Checking for updates", "Contacting GitHub to inspect the latest menu.lua build.", "Starting update check", 0.12)
		end

		local fetchOk, remoteSource = fetchRemoteMenuSource(setStatus)
		if not fetchOk then
			if setStatus then
				setStatus("Update check failed", "Could not fetch the GitHub raw file. The current menu will keep running.", "Fetch failed", 1)
			end
			logError("UPDATE", "Unable to fetch remote menu source", nil, remoteSource)
			return false
		end

		if setStatus then
			setStatus("Checking version", "Downloaded the remote script. Reading MENU_VERSION...", "Verifying remote version", 0.76)
		end

		local remoteVersion = extractRemoteVersion(remoteSource)
		if not remoteVersion then
			if setStatus then
				setStatus("Update check failed", "GitHub returned a file, but it did not contain a MENU_VERSION marker.", "Version parse failed", 1)
			end
			logError("UPDATE", "Remote source is missing MENU_VERSION", nil, REMOTE_MENU_URL)
			return false
		end

		if compareVersions(MENU_VERSION, remoteVersion) >= 0 then
			print(string.format("[UPDATE] menu.lua is current (%s)", MENU_VERSION))
			if setStatus then
				setStatus("Up to date", string.format("menu.lua is already current at %s.", MENU_VERSION), "No download required", 1)
			end
			return false
		end

		local installPath = getMenuInstallPath()
		if not installPath then
			if setStatus then
				setStatus("Update found", string.format("Remote version %s is available, but this runtime cannot self-write.", remoteVersion), "Waiting for supported file APIs", 1)
			end
			warn(string.format("[UPDATE] New version %s is available, but this runtime does not expose getscriptpath()", remoteVersion))
			return true
		end

		if not supportsLocalFileUpdates() then
			if setStatus then
				setStatus("Update found", string.format("Remote version %s is ready to install, but file APIs are unavailable.", remoteVersion), "Waiting for write access", 1)
			end
			warn(string.format("[UPDATE] New version %s is available, but file APIs are unavailable", remoteVersion))
			return true
		end

		if setStatus then
			setStatus("Downloading update", string.format("Writing the fetched GitHub source to %s.temp before replacement.", installPath), "Preparing safe swap", 0.88)
		end

		local tempPath = installPath .. UPDATE_TEMP_SUFFIX
		local backupPath = installPath .. UPDATE_BACKUP_SUFFIX

		local tempWriteOk, tempWriteErr = pcall(function()
			writefile(tempPath, remoteSource)
		end)
		if not tempWriteOk then
			logError("UPDATE", "Failed to write temp update file", tempWriteErr, tempPath)
			return false
		end

		local verifyOk, verifiedSource = pcall(function()
			return readfile(tempPath)
		end)
		if not verifyOk or verifiedSource ~= remoteSource then
			pcall(function()
				delfile(tempPath)
			end)
			logError("UPDATE", "Temp update verification failed", verifiedSource, tempPath)
			return false
		end

		if isfile(installPath) then
			local backupOk, backupErr = pcall(function()
				writefile(backupPath, readfile(installPath))
			end)
			if not backupOk then
				pcall(function()
					delfile(tempPath)
				end)
				logError("UPDATE", "Failed to create backup before update", backupErr, backupPath)
				return false
			end
		end

		local replaceOk, replaceErr = pcall(function()
			writefile(installPath, remoteSource)
		end)
		if not replaceOk then
			if isfile(backupPath) then
				pcall(function()
					writefile(installPath, readfile(backupPath))
				end)
			end
			pcall(function()
				delfile(tempPath)
			end)
			logError("UPDATE", "Failed to replace local menu.lua", replaceErr, installPath)
			return false
		end

		pcall(function()
			delfile(tempPath)
		end)

		if setStatus then
			setStatus("Update complete", string.format("menu.lua updated from %s to %s.", MENU_VERSION, remoteVersion), "Swap completed successfully", 1)
		end

		print(string.format("[UPDATE] menu.lua updated from %s to %s", MENU_VERSION, remoteVersion))
		return true
	end

	-- Global error handler for unhandled errors
	local function setupGlobalErrorHandler()
		local oldError = error
		error = function(message, level)
			logError("GLOBAL", message, debug.traceback(), {level = level})
			return oldError(message, level)
		end

		local function isExternalScriptError(sourceScript)
			if not sourceScript then
				return false
			end
			return sourceScript ~= thisScript
		end

		-- Catch script context errors
		game:GetService("ScriptContext").Error:Connect(function(message, stack, sourceScript)
			local external = isExternalScriptError(sourceScript)
			if external and not LOG_EXTERNAL_SCRIPT_ERRORS then
				return
			end

			logError("SCRIPT", message, stack, {
				script = sourceScript and sourceScript.Name or "Unknown",
				source = sourceScript and sourceScript:GetFullName() or "Unknown",
				external = external
			})
		end)
	end

	setupGlobalErrorHandler()

	task.spawn(function()
		local popupOk, popupResult = pcall(createUpdatePopup)
		if not popupOk then
			warn("[UPDATE] Could not create update popup UI.")
			if popupResult then
				warn(tostring(popupResult))
			end
			return
		end

		setUpdatePopupStatus(
			"Update Ready",
			"Click Continue Update to fetch the latest menu.lua from GitHub, or Skip Update to keep the current version.",
			"Waiting for your choice",
			0.08
		)

		local choice = "skip"
		if updatePopupState.interactionEvent then
			local okWait, waitedChoice = pcall(function()
				return updatePopupState.interactionEvent.Event:Wait()
			end)
			if okWait and type(waitedChoice) == "string" then
				choice = waitedChoice
			end
		end

		if choice ~= "continue" then
			closeUpdatePopup("Update skipped", "The current menu will keep running without checking GitHub.", 1.0)
			return
		end

		local ok, result = pcall(attemptMenuAutoUpdate, setUpdatePopupStatus)
		if not ok then
			logError("UPDATE", "Auto-update task failed", nil, result)
			closeUpdatePopup("Update check failed", "The updater hit an unexpected error while checking GitHub.", 1.4)
			return
		end

		if result then
			closeUpdatePopup("Update installed", "The GitHub version has been downloaded and applied.", 1.4)
		else
			closeUpdatePopup("Update check complete", "menu.lua is current, or the updater could not self-apply here.", 1.0)
		end
	end)

	local loadWeaponData

	loadWeaponData = function()
		if not ArsenalData then
			logCommand("WEAPON_DATA_LOAD", true, "ArsenalData not present for this game", 0)
			return
		end

		weaponDataCache = {}
		local modules = ArsenalData:GetChildren()
		local loadTasks = {}
		local loadedCount = 0
		local failedCount = 0

		-- Load modules in parallel for faster startup
		for _, weaponModule in ipairs(modules) do
			if weaponModule:IsA("ModuleScript") then
				table.insert(loadTasks, task.spawn(function()
					local success, data = pcall(require, weaponModule)
					if success and data then
						weaponDataCache[weaponModule.Name] = data
						loadedCount = loadedCount + 1
					else
						failedCount = failedCount + 1
						logError("WEAPON_DATA", string.format("Failed to load weapon data for: %s", weaponModule.Name), nil, {
							module = weaponModule.Name,
							error = tostring(data),
							class = weaponModule.ClassName
						})
					end
				end))
			else
				logError("WEAPON_DATA", string.format("Invalid weapon module type: %s", weaponModule.Name), nil, {
					name = weaponModule.Name,
					class = weaponModule.ClassName,
					expected = "ModuleScript"
				})
			end
		end

		-- Wait for all loads to complete
		for _, task in ipairs(loadTasks) do
			local success, result = pcall(function() task.wait() end)
			if not success then
				logError("WEAPON_DATA", "Task wait failed", nil, result)
			end
		end

		logCommand("WEAPON_DATA_LOAD", true, string.format("Loaded %d, Failed %d", loadedCount, failedCount), 0)
		print(string.format("Loaded %d weapon data modules, %d failed", loadedCount, failedCount))
	end

	-- Force reload weapon data (useful for debugging or if Arsenal updates)
	local function reloadWeaponData()
		print("Reloading Arsenal weapon data...")
		loadWeaponData()
	end

	-- Load weapon data on startup
	task.spawn(function()
		local success, result = safeExecute(loadWeaponData, "WEAPON_DATA_LOAD")
		if not success then
			logError("STARTUP", "Failed to load weapon data on startup", nil, result)
		end
	end)

	local function getWeaponData(weaponName)
		if not weaponDataCache[weaponName] then
			-- Try to load specific weapon data if not cached
			if ArsenalData then
				local weaponModule = ArsenalData:FindFirstChild(weaponName)
				if weaponModule and weaponModule:IsA("ModuleScript") then
					local success, data = pcall(require, weaponModule)
					if success and data then
						weaponDataCache[weaponName] = data
					end
				end
			end
		end
		return weaponDataCache[weaponName]
	end

	local function applyAdvancedWeaponMods(tool)
		local data = getWeaponData(tool.Name)
		
		-- Advanced automatic fire setup
		local fireMode = tool:FindFirstChild("FireMode") or tool:FindFirstChild("Firemode") or tool:FindFirstChild("Mode")
		if fireMode and fireMode:IsA("StringValue") then
			fireMode.Value = "Auto"
			print("Set fire mode to Auto")
		end
		
		-- Set fire rate to maximum automatic rate or custom high rate
		local fireRate = tool:FindFirstChild("FireRate") or tool:FindFirstChild("Rate")
		if fireRate and fireRate:IsA("NumberValue") then
			if data.FireRate and data.FireRate.Auto then
				fireRate.Value = math.max(data.FireRate.Auto * 4, 0.01)  -- Quadruple the auto rate or minimum 0.01
			else
				fireRate.Value = 0.01
			end
		end
		
		-- Modify recoil and spread for better control
		local recoilValues = {"Recoil", "Kick", "CameraRecoil", "GunRecoil", "WeaponRecoil"}
		for _, name in ipairs(recoilValues) do
			local recoil = tool:FindFirstChild(name)
			if recoil and (recoil:IsA("NumberValue") or recoil:IsA("Vector3Value")) then
				if recoil:IsA("Vector3Value") then
					recoil.Value = Vector3.new(0, 0, 0)
				else
					recoil.Value = 0
				end
			end
		end
		
		-- Modify spread and inaccuracy
		local spreadValues = {"Spread", "Inaccuracy", "Deviation", "Bloom"}
		for _, name in ipairs(spreadValues) do
			local spread = tool:FindFirstChild(name)
			if spread and spread:IsA("NumberValue") then
				spread.Value = 0
			end
		end
		
		-- Modify reload and other properties for advantage - SUPER FAST RELOAD
		local reloadValues = {"ReloadTime", "Reload", "ReloadDuration", "ReloadDelay", "EquipTime", "DeployTime"}
		local reloadOptimized = false
		for _, name in ipairs(reloadValues) do
			local reloadTime = tool:FindFirstChild(name)
			if reloadTime and reloadTime:IsA("NumberValue") then
				local oldValue = reloadTime.Value
				-- Use Arsenal data for optimal reload time if available, otherwise set to extremely fast
				if data.ReloadTime and data.ReloadTime > 0 then
					reloadTime.Value = math.max(data.ReloadTime * 0.005, 0.0005)  -- 0.5% of original or minimum 0.0005
				elseif data.Reload and data.Reload > 0 then
					reloadTime.Value = math.max(data.Reload * 0.005, 0.0005)
				else
					reloadTime.Value = 0.0005  -- Extremely fast reload
				end
				print("Optimized", name, "from", oldValue, "to", reloadTime.Value)
				reloadOptimized = true
			end
		end
		if reloadOptimized then
			print("Super fast reload applied!")
		end
		
		-- Additional weapon speed optimizations
		local speedValues = {"ProjectileSpeed", "BulletSpeed", "MuzzleVelocity", "Velocity"}
		for _, name in ipairs(speedValues) do
			local speed = tool:FindFirstChild(name)
			if speed and speed:IsA("NumberValue") then
				if data[name] and data[name] > 0 then
					speed.Value = math.max(data[name] * 3, speed.Value)  -- 200% faster projectiles
				else
					speed.Value = math.max(speed.Value * 2.4, 1000)  -- Minimum speed boost
				end
			end
		end
		
		local ammoCapacity = tool:FindFirstChild("Ammo") or tool:FindFirstChild("MagazineSize") or tool:FindFirstChild("ClipSize")
		if ammoCapacity and ammoCapacity:IsA("IntValue") then
			-- Use Arsenal data for ammo if available, otherwise triple it
			if data.Ammo and data.Ammo > 0 then
				ammoCapacity.Value = math.max(data.Ammo * 6, ammoCapacity.Value * 3)  -- Sextuple Arsenal ammo or triple current
			else
				ammoCapacity.Value = ammoCapacity.Value * 6  -- Sextuple ammo for less reloading
			end
		end
	end
	local Lighting = game:GetService("Lighting")
	local Teams = game:GetService("Teams")

	local player = Players.LocalPlayer

	local aimbotFOV = 120
	local cameraFovState = {
		value = 70,
		default = nil,
		boundCamera = nil,
		cameraSignal = nil,
		cameraSwapSignal = nil,
	}
	local crosshairSettings = {
		size = 8,
		thickness = 2,
		glowThickness = 4,
		opacity = 0.8,
		glowOpacity = 0.2
	}

	function tweenUI(inst, duration, props)
		if type(duration) == "table" and props == nil then
			props = duration
			duration = 0.12
		end
		TweenService:Create(inst, TweenInfo.new(duration or 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
	end

	-- =============== CORE MENU UI ===============
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "GROK_GANGSTA_MENU"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 10
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = game:GetService("CoreGui")

	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MenuBox"
	mainFrame.Size = UDim2.new(0, 520, 0, 400)
	mainFrame.Position = UDim2.new(0.5, -260, 0.5, -200)
	mainFrame.AnchorPoint = Vector2.new(0, 0)
	mainFrame.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
	mainFrame.BackgroundTransparency = 0.02
	mainFrame.ZIndex = 9999
	mainFrame.Parent = screenGui

	local mainScale = Instance.new("UIScale")
	mainScale.Scale = 1
	mainScale.Parent = mainFrame

	local menuAnimState = {
		isAnimating = false,
		visibleTarget = true,
		currentTween = nil,
	}

	local function setMenuVisible(visible)
		menuAnimState.visibleTarget = visible
		if menuAnimState.currentTween then
			menuAnimState.currentTween:Cancel()
			menuAnimState.currentTween = nil
		end

		menuAnimState.isAnimating = true
		if visible then
			mainFrame.Visible = true
			mainScale.Scale = 0.935
			local tweenIn = TweenService:Create(mainScale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Scale = 1,
			})
			menuAnimState.currentTween = tweenIn
			tweenIn.Completed:Connect(function()
				if menuAnimState.currentTween == tweenIn then
					menuAnimState.currentTween = nil
				end
				menuAnimState.isAnimating = false
			end)
			tweenIn:Play()
		else
			local tweenOut = TweenService:Create(mainScale, TweenInfo.new(0.15, Enum.EasingStyle.Cubic, Enum.EasingDirection.In), {
				Scale = 0.935,
			})
			menuAnimState.currentTween = tweenOut
			tweenOut.Completed:Connect(function()
				if menuAnimState.currentTween == tweenOut then
					menuAnimState.currentTween = nil
				end
				if not menuAnimState.visibleTarget then
					mainFrame.Visible = false
					mainScale.Scale = 1
				end
				menuAnimState.isAnimating = false
			end)
			tweenOut:Play()
		end
	end

	local ACTION_BLOCK_BACKSPACE = "GGM_BlockBackspace"
	local ACTION_BLOCK_SPACE_WHEN_MENU_OPEN = "GGM_BlockSpaceWhenMenuOpen"
	local INPUT_BLOCK_PRIORITY = Enum.ContextActionPriority.High.Value + 1000

	ContextActionService:BindActionAtPriority(
		ACTION_BLOCK_BACKSPACE,
		function()
			return Enum.ContextActionResult.Sink
		end,
		false,
		INPUT_BLOCK_PRIORITY,
		Enum.KeyCode.Backspace
	)

	ContextActionService:BindActionAtPriority(
		ACTION_BLOCK_SPACE_WHEN_MENU_OPEN,
		function()
			if mainFrame.Visible then
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end,
		false,
		INPUT_BLOCK_PRIORITY,
		Enum.KeyCode.Space
	)

	-- Main container border and corner styling.
	do
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 14)
		c.Parent = mainFrame
	end

	local mainStroke = Instance.new("UIStroke")
	mainStroke.Color = Color3.fromRGB(255, 40, 80)
	mainStroke.Thickness = 1.4
	mainStroke.Transparency = 0.38
	mainStroke.Parent = mainFrame

	do
		local g = Instance.new("UIGradient")
		g.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(18, 18, 26)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(12, 12, 18)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 8, 14)),
		})
		g.Rotation = 155
		g.Parent = mainFrame
	end

	-- Decorative rain layer inside the menu container.
	local rainLayer = Instance.new("Frame")
	rainLayer.Name = "RainLayer"
	rainLayer.Size = UDim2.new(1, 0, 1, 0)
	rainLayer.BackgroundTransparency = 1
	rainLayer.BorderSizePixel = 0
	rainLayer.ClipsDescendants = true
	rainLayer.ZIndex = 9998
	rainLayer.Parent = mainFrame

	-- =============== TOP BAR HEADER ===============
	local topBar = Instance.new("Frame")
	topBar.Name = "TopBar"
	topBar.Size = UDim2.new(1, 0, 0, 44)
	topBar.BackgroundColor3 = Color3.fromRGB(16, 16, 24)
	topBar.BackgroundTransparency = 0.15
	topBar.BorderSizePixel = 0
	topBar.ClipsDescendants = true
	topBar.Parent = mainFrame

	do
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 14)
		c.Parent = topBar

		local d = Instance.new("Frame")
		d.Size = UDim2.new(1, 0, 0, 1)
		d.Position = UDim2.new(0, 0, 1, -1)
		d.BackgroundColor3 = Color3.fromRGB(255, 40, 80)
		d.BackgroundTransparency = 0.76
		d.BorderSizePixel = 0
		d.Parent = topBar
	end

	-- Username label with outline/glow support.
	local usernameLabel = Instance.new("TextLabel")
	usernameLabel.Name = "Username"
	usernameLabel.Size = UDim2.new(0.6, 0, 1, 0)
	usernameLabel.Position = UDim2.new(0, 16, 0, 0)
	usernameLabel.BackgroundTransparency = 1
	usernameLabel.Text = player.Name
	usernameLabel.TextColor3 = Color3.fromRGB(240, 240, 248)
	usernameLabel.TextSize = 18
	usernameLabel.Font = Enum.Font.GothamBlack
	usernameLabel.TextXAlignment = Enum.TextXAlignment.Left
	usernameLabel.Parent = topBar

	local usernameStroke = Instance.new("UIStroke")
	usernameStroke.Color = Color3.fromRGB(0, 0, 0)
	usernameStroke.Thickness = 2
	usernameStroke.Transparency = 0.5
	usernameStroke.Parent = usernameLabel

	-- Brand label on the top-right corner.
	local grokMark = Instance.new("TextLabel")
	grokMark.Size = UDim2.new(0, 100, 0, 20)
	grokMark.Position = UDim2.new(1, -112, 0.5, -10)
	grokMark.BackgroundTransparency = 1
	grokMark.Text = "NEUSENCE"
	grokMark.TextColor3 = Color3.fromRGB(255, 50, 90)
	grokMark.TextSize = 13
	grokMark.Font = Enum.Font.GothamBlack
	grokMark.TextTransparency = 0.1
	grokMark.Parent = topBar

	do
		local h = Instance.new("TextLabel")
		h.Size = UDim2.new(0, 100, 0, 14)
		h.Position = UDim2.new(1, -112, 0.5, 6)
		h.BackgroundTransparency = 1
		h.Text = "[INSERT] toggle"
		h.TextColor3 = Color3.fromRGB(100, 105, 120)
		h.TextSize = 11
		h.Font = Enum.Font.GothamMedium
		h.TextXAlignment = Enum.TextXAlignment.Right
		h.TextTransparency = 0.15
		h.Parent = topBar
	end

	-- =============== TAB NAVIGATION ===============
	local tabsFrame = Instance.new("Frame")
	tabsFrame.Size = UDim2.new(1, -20, 0, 32)
	tabsFrame.Position = UDim2.new(0, 10, 0, 48)
	tabsFrame.BackgroundTransparency = 1
	tabsFrame.Parent = mainFrame

	local TAB_INDICATOR_INSET = 12
	local TAB_INDICATOR_HEIGHT = 4
	local TAB_INDICATOR_BOTTOM_PADDING = 0

	local tabIndicator = Instance.new("Frame")
	tabIndicator.Name = "TabIndicator"
	tabIndicator.Size = UDim2.new(0.235, -((TAB_INDICATOR_INSET * 2) + 4), 0, TAB_INDICATOR_HEIGHT)
	tabIndicator.Position = UDim2.new(0, TAB_INDICATOR_INSET + 2, 1, -(TAB_INDICATOR_HEIGHT + TAB_INDICATOR_BOTTOM_PADDING))
	tabIndicator.BackgroundColor3 = Color3.fromRGB(255, 62, 98)
	tabIndicator.BorderSizePixel = 0
	tabIndicator.ZIndex = 4
	tabIndicator.Parent = tabsFrame

	do
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = tabIndicator

		local g = Instance.new("UIGradient")
		g.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 72, 108)),
			ColorSequenceKeypoint.new(0.55, Color3.fromRGB(255, 50, 90)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 118, 154)),
		})
		g.Parent = tabIndicator
	end

	local visualTab = Instance.new("TextButton")
	visualTab.Size = UDim2.new(0.235, -4, 1, 0)
	visualTab.Position = UDim2.new(0, 0, 0, 0)
	visualTab.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
	visualTab.Text = "VISUALS"
	visualTab.TextColor3 = Color3.fromRGB(210, 214, 226)
	visualTab.TextSize = 13
	visualTab.Font = Enum.Font.GothamBlack
	visualTab.Parent = tabsFrame

	local combatTab = Instance.new("TextButton")
	combatTab.Size = UDim2.new(0.235, -4, 1, 0)
	combatTab.Position = UDim2.new(0.255, 0, 0, 0)
	combatTab.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
	combatTab.Text = "COMBAT"
	combatTab.TextColor3 = Color3.fromRGB(210, 214, 226)
	combatTab.TextSize = 13
	combatTab.Font = Enum.Font.GothamBlack
	combatTab.Parent = tabsFrame

	local worldTab = Instance.new("TextButton")
	worldTab.Size = UDim2.new(0.235, -4, 1, 0)
	worldTab.Position = UDim2.new(0.51, 0, 0, 0)
	worldTab.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
	worldTab.Text = "WORLD"
	worldTab.TextColor3 = Color3.fromRGB(210, 214, 226)
	worldTab.TextSize = 13
	worldTab.Font = Enum.Font.GothamBlack
	worldTab.Parent = tabsFrame

	local settingsTab = Instance.new("TextButton")
	settingsTab.Size = UDim2.new(0.235, -4, 1, 0)
	settingsTab.Position = UDim2.new(0.765, 0, 0, 0)
	settingsTab.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
	settingsTab.Text = "SETTINGS"
	settingsTab.TextColor3 = Color3.fromRGB(210, 214, 226)
	settingsTab.TextSize = 13
	settingsTab.Font = Enum.Font.GothamBlack
	settingsTab.Parent = tabsFrame

	-- Tab styling
	local tabStrokes = {}
	local tabScales = {}
	local tabHoverState = {}
	local tabIndicatorTween = nil
	for _, tab in ipairs({visualTab, combatTab, worldTab, settingsTab}) do
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = tab

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(58, 60, 76)
		stroke.Transparency = 0.56
		stroke.Thickness = 1
		stroke.Parent = tab
		tabStrokes[#tabStrokes + 1] = stroke

		local scale = Instance.new("UIScale")
		scale.Scale = 1
		scale.Parent = tab
		tabScales[tab] = scale
		tabHoverState[tab] = false
	end

	local contentFrame = Instance.new("Frame")
	contentFrame.Size = UDim2.new(1, -20, 1, -95)
	contentFrame.Position = UDim2.new(0, 10, 0, 88)
	contentFrame.BackgroundTransparency = 1
	contentFrame.Parent = mainFrame

	local visualContent = Instance.new("Frame")
	visualContent.Size = UDim2.new(1,0,1,0)
	visualContent.BackgroundTransparency = 1
	visualContent.Visible = true
	visualContent.Parent = contentFrame

	local combatContent = Instance.new("ScrollingFrame")
	combatContent.Size = UDim2.new(1,0,1,0)
	combatContent.BackgroundTransparency = 1
	combatContent.ScrollBarThickness = 4
	combatContent.ScrollBarImageColor3 = Color3.fromRGB(255, 40, 80)
	combatContent.ScrollBarImageTransparency = 0.3
	combatContent.CanvasSize = UDim2.new(0,0,0,392)
	combatContent.ClipsDescendants = true
	combatContent.Visible = false
	combatContent.Parent = contentFrame

	local worldContent = Instance.new("ScrollingFrame")
	worldContent.Size = UDim2.new(1,0,1,0)
	worldContent.BackgroundTransparency = 1
	worldContent.ScrollBarThickness = 4
	worldContent.ScrollBarImageColor3 = Color3.fromRGB(255, 40, 80)
	worldContent.ScrollBarImageTransparency = 0.3
	worldContent.CanvasSize = UDim2.new(0,0,0,392)
	worldContent.ClipsDescendants = true
	worldContent.Visible = false
	worldContent.Parent = contentFrame

	local settingsContent = Instance.new("ScrollingFrame")
	settingsContent.Size = UDim2.new(1,0,1,0)
	settingsContent.BackgroundTransparency = 1
	settingsContent.ScrollBarThickness = 4
	settingsContent.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 100)
	settingsContent.ScrollBarImageTransparency = 0.3
	settingsContent.CanvasSize = UDim2.new(0,0,0,0)
	settingsContent.AutomaticCanvasSize = Enum.AutomaticSize.Y
	settingsContent.ClipsDescendants = true
	settingsContent.Visible = false
	settingsContent.Parent = contentFrame

	do
		local p = Instance.new("UIPadding")
		p.PaddingTop = UDim.new(0, 2)
		p.PaddingBottom = UDim.new(0, 8)
		p.Parent = settingsContent

		local l = Instance.new("UIListLayout")
		l.FillDirection = Enum.FillDirection.Vertical
		l.HorizontalAlignment = Enum.HorizontalAlignment.Left
		l.SortOrder = Enum.SortOrder.LayoutOrder
		l.Padding = UDim.new(0, 8)
		l.Parent = settingsContent
	end

	local rgbFills = {}
	local rgbStrokes = {}
	local fireRateState = {
		shootRate = 0.008
	}
	local worldFx
	local applyWorldFx
	local applyCustomSky
	local updateWorldFxStatus
	local noRecoilState

	local function createModernCheckbox(parent)
		-- Modern pill-style toggle switch
		local track = Instance.new("Frame")
		track.Size = UDim2.new(0, 42, 0, 22)
		track.Position = UDim2.new(1, -56, 0.5, -11)
		track.BackgroundColor3 = Color3.fromRGB(33, 34, 45)
		track.ZIndex = (parent.ZIndex or 1) + 2
		track.Parent = parent

		local trackCorner = Instance.new("UICorner")
		trackCorner.CornerRadius = UDim.new(1, 0)
		trackCorner.Parent = track

		local trackStroke = Instance.new("UIStroke")
		trackStroke.Color = Color3.fromRGB(60, 60, 75)
		trackStroke.Thickness = 1.2
		trackStroke.Parent = track

		local thumb = Instance.new("Frame")
		thumb.Size = UDim2.new(0, 16, 0, 16)
		thumb.Position = UDim2.new(0, 3, 0.5, -8)
		thumb.BackgroundColor3 = Color3.fromRGB(126, 128, 142)
		thumb.ZIndex = track.ZIndex + 1
		thumb.Parent = track

		local thumbCorner = Instance.new("UICorner")
		thumbCorner.CornerRadius = UDim.new(1, 0)
		thumbCorner.Parent = thumb

		local thumbScale = Instance.new("UIScale")
		thumbScale.Scale = 1
		thumbScale.Parent = thumb

		local function setState(enabled)
			local activeColor = (visualState and visualState.currentRgbColor) or Color3.fromRGB(255, 40, 80)
			if enabled then
				track.BackgroundColor3 = activeColor
				trackStroke.Color = activeColor
				rgbFills[track] = true
				rgbStrokes[trackStroke] = true
				TweenService:Create(thumb, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Position = UDim2.new(1, -19, 0.5, -8),
					BackgroundColor3 = Color3.fromRGB(255, 255, 255),
				}):Play()
				thumbScale.Scale = 0.85
				TweenService:Create(thumbScale, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()
			else
				track.BackgroundColor3 = Color3.fromRGB(33, 34, 45)
				trackStroke.Color = Color3.fromRGB(60, 60, 75)
				rgbFills[track] = nil
				rgbStrokes[trackStroke] = nil
				TweenService:Create(thumb, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Position = UDim2.new(0, 3, 0.5, -8),
					BackgroundColor3 = Color3.fromRGB(126, 128, 142),
				}):Play()
			end
		end

		setState(false)
		return setState
	end

	-- =============== VISUALS CONTROLS ===============

	local espToggle = Instance.new("TextButton")
	espToggle.Size = UDim2.new(1, 0, 0, 40)
	espToggle.Position = UDim2.new(0, 0, 0, 6)
	espToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	espToggle.Text = "  Skeleton Chams"
	espToggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	espToggle.TextSize = 15
	espToggle.Font = Enum.Font.GothamBold
	espToggle.TextXAlignment = Enum.TextXAlignment.Left
	espToggle.Parent = visualContent

	local setEspCheck = createModernCheckbox(espToggle)
	setEspCheck(false)

	espToggle.MouseEnter:Connect(function()
		tweenUI(espToggle, {BackgroundColor3 = Color3.fromRGB(30, 30, 40)})
	end)
	espToggle.MouseLeave:Connect(function()
		tweenUI(espToggle, {BackgroundColor3 = Color3.fromRGB(22, 22, 30)})
	end)

	-- Weapon Chams toggle
	local chamsToggle = Instance.new("TextButton")
	chamsToggle.Size = UDim2.new(1, 0, 0, 40)
	chamsToggle.Position = UDim2.new(0, 0, 0, 52)
	chamsToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	chamsToggle.Text = "  Weapon Chams"
	chamsToggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	chamsToggle.TextSize = 15
	chamsToggle.Font = Enum.Font.GothamBold
	chamsToggle.TextXAlignment = Enum.TextXAlignment.Left
	chamsToggle.Parent = visualContent

	local setChamsCheck = createModernCheckbox(chamsToggle)
	setChamsCheck(false)

	chamsToggle.MouseEnter:Connect(function()
		tweenUI(chamsToggle, {BackgroundColor3 = Color3.fromRGB(30, 30, 40)})
	end)
	chamsToggle.MouseLeave:Connect(function()
		tweenUI(chamsToggle, {BackgroundColor3 = Color3.fromRGB(22, 22, 30)})
	end)

	local renderUsernamesState = {
		enabled = false,
		connections = {},
		clearAll = nil,
		toggle = nil,
		setCheck = nil,
		updateConnection = nil,
		updateAccumulator = 0,
		scanCursor = 0,
		avatarCache = {},
	}

	renderUsernamesState.toggle = Instance.new("TextButton")
	renderUsernamesState.toggle.Size = UDim2.new(1, 0, 0, 40)
	renderUsernamesState.toggle.Position = UDim2.new(0, 0, 0, 98)
	renderUsernamesState.toggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	renderUsernamesState.toggle.Text = "  Render Usernames"
	renderUsernamesState.toggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	renderUsernamesState.toggle.TextSize = 15
	renderUsernamesState.toggle.Font = Enum.Font.GothamBold
	renderUsernamesState.toggle.TextXAlignment = Enum.TextXAlignment.Left
	renderUsernamesState.toggle.Parent = visualContent

	renderUsernamesState.setCheck = createModernCheckbox(renderUsernamesState.toggle)
	renderUsernamesState.setCheck(false)

	renderUsernamesState.toggle.MouseEnter:Connect(function()
		tweenUI(renderUsernamesState.toggle, {BackgroundColor3 = Color3.fromRGB(30, 30, 40)})
	end)
	renderUsernamesState.toggle.MouseLeave:Connect(function()
		tweenUI(renderUsernamesState.toggle, {BackgroundColor3 = Color3.fromRGB(22, 22, 30)})
	end)

	local visualModeStatus = Instance.new("TextLabel")
	visualModeStatus.Size = UDim2.new(1, 0, 0, 28)
	visualModeStatus.Position = UDim2.new(0, 0, 0, 146)
	visualModeStatus.BackgroundTransparency = 1
	visualModeStatus.Text = "Visual Loop: Internal (RenderStepped)"
	visualModeStatus.TextColor3 = Color3.fromRGB(100, 105, 120)
	visualModeStatus.TextSize = 12
	visualModeStatus.Font = Enum.Font.GothamMedium
	visualModeStatus.TextXAlignment = Enum.TextXAlignment.Left
	visualModeStatus.Parent = visualContent
	do
		local cameraFovRow = Instance.new("TextLabel")
		cameraFovRow.Size = UDim2.new(1, 0, 0, 40)
		cameraFovRow.Position = UDim2.new(0, 0, 0, 174)
		cameraFovRow.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
		cameraFovRow.Text = "  Camera FOV"
		cameraFovRow.TextColor3 = Color3.fromRGB(210, 212, 220)
		cameraFovRow.TextSize = 15
		cameraFovRow.Font = Enum.Font.GothamBold
		cameraFovRow.TextXAlignment = Enum.TextXAlignment.Left
		cameraFovRow.Parent = visualContent

		local cameraFovInput = Instance.new("TextBox")
		cameraFovInput.Size = UDim2.new(0, 80, 0, 26)
		cameraFovInput.Position = UDim2.new(1, -96, 0.5, -13)
		cameraFovInput.BackgroundColor3 = Color3.fromRGB(16, 16, 22)
		cameraFovInput.TextColor3 = Color3.fromRGB(220, 222, 230)
		cameraFovInput.TextSize = 14
		cameraFovInput.Font = Enum.Font.GothamBold
		cameraFovInput.PlaceholderText = "70"
		cameraFovInput.Parent = cameraFovRow

		do
			local rowCorner = Instance.new("UICorner")
			rowCorner.CornerRadius = UDim.new(0, 7)
			rowCorner.Parent = cameraFovRow

			local rowStroke = Instance.new("UIStroke")
			rowStroke.Color = Color3.fromRGB(40, 42, 55)
			rowStroke.Transparency = 0.35
			rowStroke.Thickness = 1
			rowStroke.Parent = cameraFovRow

			local inputCorner = Instance.new("UICorner")
			inputCorner.CornerRadius = UDim.new(0, 6)
			inputCorner.Parent = cameraFovInput

			local inputStroke = Instance.new("UIStroke")
			inputStroke.Color = Color3.fromRGB(55, 55, 70)
			inputStroke.Thickness = 1.2
			inputStroke.Transparency = 0.25
			inputStroke.Parent = cameraFovInput

			cameraFovInput.Focused:Connect(function()
				tweenUI(cameraFovInput, 0.1, {BackgroundColor3 = Color3.fromRGB(24, 24, 32)})
				tweenUI(inputStroke, 0.1, {Transparency = 0.02})
			end)

			cameraFovInput.FocusLost:Connect(function()
				tweenUI(cameraFovInput, 0.12, {BackgroundColor3 = Color3.fromRGB(16, 16, 22)})
				tweenUI(inputStroke, 0.12, {Transparency = 0.25})
				local nextValue = tonumber(cameraFovInput.Text)
				if nextValue then
					cameraFovState.value = math.clamp(math.floor(nextValue + 0.5), 40, 200)
				end
				cameraFovInput.Text = tostring(cameraFovState.value)
				local cam = workspace.CurrentCamera
				if cam then
					if cameraFovState.default == nil then
						cameraFovState.default = cam.FieldOfView
					end
					cam.FieldOfView = cameraFovState.value
				end
			end)
		end

		local cam = workspace.CurrentCamera
		if cam then
			cameraFovState.default = cam.FieldOfView
			cameraFovState.value = math.clamp(math.floor(cam.FieldOfView + 0.5), 40, 200)
		end
		cameraFovInput.Text = tostring(cameraFovState.value)
	end
	do
		local usernameTagName = "CharacterMenuUsernameTag"

		local function shouldDisplayRenderUsernameForPlayer(targetPlayer)
			if not renderUsernamesState.enabled then
				return false
			end

			if targetPlayer == player then
				return false
			end

			local localTeam = player.Team
			local targetTeam = targetPlayer.Team

			if localTeam and targetTeam then
				return localTeam ~= targetTeam
			end

			if player.TeamColor ~= nil and targetPlayer.TeamColor ~= nil then
				return player.TeamColor ~= targetPlayer.TeamColor
			end

			return false
		end

		local function removeRenderUsernameFromCharacter(character)
			if not character then
				return
			end

			local existing = character:FindFirstChild(usernameTagName)
			if existing then
				existing:Destroy()
			end
		end

		local function createRenderUsernameForPlayer(targetPlayer)
			if not shouldDisplayRenderUsernameForPlayer(targetPlayer) then
				return
			end

			local character = targetPlayer.Character
			if not character then
				return
			end

			local head = character:FindFirstChild("Head")
			if not head then
				return
			end

			local existingBillboard = character:FindFirstChild(usernameTagName)
			if existingBillboard and existingBillboard:IsA("BillboardGui") and existingBillboard.Adornee == head then
				return
			end

			removeRenderUsernameFromCharacter(character)

			local usernameText = "@" .. targetPlayer.Name
			local textSize = TextService:GetTextSize(usernameText, 12, Enum.Font.GothamMedium, Vector2.new(1000, 24))
			local billboardWidth = math.clamp(textSize.X + 36, 78, 220)

			local billboard = Instance.new("BillboardGui")
			billboard.Name = usernameTagName
			billboard.Adornee = head
			billboard.AlwaysOnTop = true
			billboard.Size = UDim2.new(0, billboardWidth, 0, 24)
			billboard.StudsOffset = Vector3.new(0, 2.55, 0)
			billboard.MaxDistance = 180
			billboard.Parent = character

			local background = Instance.new("Frame")
			background.Size = UDim2.new(1, 0, 1, 0)
			background.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			background.BackgroundTransparency = 1
			background.BorderSizePixel = 0
			background.Parent = billboard

			local backgroundCorner = Instance.new("UICorner")
			backgroundCorner.CornerRadius = UDim.new(1, 0)
			backgroundCorner.Parent = background

			local avatarImage = Instance.new("ImageLabel")
			avatarImage.Name = "AvatarHeadshot"
			avatarImage.Size = UDim2.new(0, 18, 0, 18)
			avatarImage.Position = UDim2.new(0, 4, 0.5, 0)
			avatarImage.AnchorPoint = Vector2.new(0, 0.5)
			avatarImage.BackgroundTransparency = 1
			avatarImage.ImageTransparency = 1
			avatarImage.Parent = background

			local avatarCorner = Instance.new("UICorner")
			avatarCorner.CornerRadius = UDim.new(1, 0)
			avatarCorner.Parent = avatarImage

			local label = Instance.new("TextLabel")
			label.Size = UDim2.new(1, -28, 1, 0)
			label.Position = UDim2.new(0, 26, 0, 0)
			label.BackgroundTransparency = 1
			label.TextScaled = false
			label.TextSize = 12
			label.Font = Enum.Font.GothamMedium
			label.TextColor3 = Color3.fromRGB(255, 255, 255)
			label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
			label.TextTransparency = 1
			label.TextStrokeTransparency = 1
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.Text = usernameText
			label.Parent = billboard

			task.spawn(function()
				TweenService:Create(background, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					BackgroundTransparency = 0.28,
				}):Play()

				TweenService:Create(label, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					TextTransparency = 0,
					TextStrokeTransparency = 0,
				}):Play()

				local cachedImage = renderUsernamesState.avatarCache[targetPlayer.UserId]
				if cachedImage and avatarImage.Parent then
					avatarImage.Image = cachedImage
					TweenService:Create(avatarImage, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						ImageTransparency = 0,
					}):Play()
				else
					local ok, image = pcall(function()
						local thumbnail, _ = Players:GetUserThumbnailAsync(
							targetPlayer.UserId,
							Enum.ThumbnailType.HeadShot,
							Enum.ThumbnailSize.Size48x48
						)
						return thumbnail
					end)

					if ok and image and avatarImage.Parent then
						renderUsernamesState.avatarCache[targetPlayer.UserId] = image
						avatarImage.Image = image
						TweenService:Create(avatarImage, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
							ImageTransparency = 0,
						}):Play()
					end
				end
			end)
		end

		local function refreshRenderUsernameForPlayer(targetPlayer)
			if shouldDisplayRenderUsernameForPlayer(targetPlayer) then
				createRenderUsernameForPlayer(targetPlayer)
			elseif targetPlayer.Character then
				removeRenderUsernameFromCharacter(targetPlayer.Character)
			end
		end

		local function clearAllRenderUsernames()
			for _, targetPlayer in ipairs(Players:GetPlayers()) do
				if targetPlayer.Character then
					removeRenderUsernameFromCharacter(targetPlayer.Character)
				end
			end
		end

		local function refreshAllRenderUsernames()
			for _, targetPlayer in ipairs(Players:GetPlayers()) do
				refreshRenderUsernameForPlayer(targetPlayer)
			end
		end

		local function updateRenderUsernameVisibilityForPlayer(targetPlayer)
			if not targetPlayer then
				return
			end
			local character = targetPlayer.Character
			if not character then
				return
			end
			local billboard = character:FindFirstChild(usernameTagName)
			if not billboard or not billboard:IsA("BillboardGui") then
				return
			end
			if not shouldDisplayRenderUsernameForPlayer(targetPlayer) then
				billboard.Enabled = false
				return
			end
			local head = character:FindFirstChild("Head")
			local camera = workspace.CurrentCamera
			if not head or not camera then
				billboard.Enabled = false
				return
			end
			local viewportPos, onScreen = camera:WorldToViewportPoint(head.Position)
			if not onScreen or viewportPos.Z <= 0 then
				billboard.Enabled = false
				return
			end
			local distance = (camera.CFrame.Position - head.Position).Magnitude
			billboard.Enabled = distance <= billboard.MaxDistance
		end

		local function stopRenderUsernameUpdater()
			if renderUsernamesState.updateConnection then
				renderUsernamesState.updateConnection:Disconnect()
				renderUsernamesState.updateConnection = nil
			end
			renderUsernamesState.updateAccumulator = 0
		end

		local function startRenderUsernameUpdater()
			if renderUsernamesState.updateConnection then
				return
			end
			renderUsernamesState.updateConnection = RunService.RenderStepped:Connect(function(dt)
				if not renderUsernamesState.enabled then
					return
				end
				renderUsernamesState.updateAccumulator = renderUsernamesState.updateAccumulator + dt
				if renderUsernamesState.updateAccumulator < 0.05 then
					return
				end
				renderUsernamesState.updateAccumulator = 0

				local allPlayers = Players:GetPlayers()
				local totalPlayers = #allPlayers
				if totalPlayers == 0 then
					return
				end

				for _ = 1, math.min(8, totalPlayers) do
					renderUsernamesState.scanCursor = (renderUsernamesState.scanCursor % totalPlayers) + 1
					local targetPlayer = allPlayers[renderUsernamesState.scanCursor]
					if targetPlayer then
						refreshRenderUsernameForPlayer(targetPlayer)
						updateRenderUsernameVisibilityForPlayer(targetPlayer)
					end
				end
			end)
		end

		local function unbindRenderUsernamePlayer(targetPlayer)
			local connections = renderUsernamesState.connections[targetPlayer]
			if connections then
				for _, conn in ipairs(connections) do
					conn:Disconnect()
				end
				renderUsernamesState.connections[targetPlayer] = nil
			end
			if targetPlayer and targetPlayer.Character then
				removeRenderUsernameFromCharacter(targetPlayer.Character)
			end
		end

		local function bindRenderUsernamePlayer(targetPlayer)
			unbindRenderUsernamePlayer(targetPlayer)

			renderUsernamesState.connections[targetPlayer] = {
				targetPlayer:GetPropertyChangedSignal("Team"):Connect(function()
					refreshRenderUsernameForPlayer(targetPlayer)
				end),
				targetPlayer.CharacterAdded:Connect(function(character)
					character:WaitForChild("Head", 5)
					task.wait(0.1)
					refreshRenderUsernameForPlayer(targetPlayer)
				end),
			}
		end

		renderUsernamesState.clearAll = clearAllRenderUsernames

		renderUsernamesState.toggle.MouseButton1Click:Connect(function()
			renderUsernamesState.enabled = not renderUsernamesState.enabled
			renderUsernamesState.setCheck(renderUsernamesState.enabled)

			if renderUsernamesState.enabled then
				renderUsernamesState.scanCursor = 0
				renderUsernamesState.updateAccumulator = 0
				refreshAllRenderUsernames()
				startRenderUsernameUpdater()
			else
				stopRenderUsernameUpdater()
				clearAllRenderUsernames()
			end
		end)

		for _, targetPlayer in ipairs(Players:GetPlayers()) do
			bindRenderUsernamePlayer(targetPlayer)
		end

		Players.PlayerAdded:Connect(function(targetPlayer)
			bindRenderUsernamePlayer(targetPlayer)
			task.wait(0.2)
			refreshRenderUsernameForPlayer(targetPlayer)
		end)

		Players.PlayerRemoving:Connect(function(targetPlayer)
			unbindRenderUsernamePlayer(targetPlayer)
		end)

		player.CharacterAppearanceLoaded:Connect(function()
			refreshRenderUsernameForPlayer(player)
		end)

		player.CharacterAdded:Connect(function()
			task.wait(0.5)
			refreshRenderUsernameForPlayer(player)
		end)

		player:GetPropertyChangedSignal("Team"):Connect(function()
			renderUsernamesState.scanCursor = 0
			refreshAllRenderUsernames()
		end)

		player:GetPropertyChangedSignal("TeamColor"):Connect(function()
			renderUsernamesState.scanCursor = 0
			refreshAllRenderUsernames()
		end)

		task.spawn(function()
			refreshAllRenderUsernames()
		end)
	end

	-- =============== WORLD CONTROLS ===============
	local worldBrightNightStrength = 1
	local brightNightToggle = Instance.new("TextButton")
	brightNightToggle.Size = UDim2.new(1, 0, 0, 40)
	brightNightToggle.Position = UDim2.new(0, 0, 0, 6)
	brightNightToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	brightNightToggle.Text = "  Bright Night"
	brightNightToggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	brightNightToggle.TextSize = 15
	brightNightToggle.Font = Enum.Font.GothamBold
	brightNightToggle.TextXAlignment = Enum.TextXAlignment.Left
	brightNightToggle.Parent = worldContent

	local setBrightNightCheck = createModernCheckbox(brightNightToggle)
	setBrightNightCheck(false)

	local worldModeStatus = Instance.new("TextLabel")
	worldModeStatus.Size = UDim2.new(1, 0, 0, 28)
	worldModeStatus.Position = UDim2.new(0, 0, 0, 50)
	worldModeStatus.BackgroundTransparency = 1
	worldModeStatus.Text = "World FX: Default Lighting"
	worldModeStatus.TextColor3 = Color3.fromRGB(100, 105, 120)
	worldModeStatus.TextSize = 12
	worldModeStatus.Font = Enum.Font.GothamMedium
	worldModeStatus.TextXAlignment = Enum.TextXAlignment.Left
	worldModeStatus.Parent = worldContent

	local brightNightStrengthRow = Instance.new("TextLabel")
	brightNightStrengthRow.Size = UDim2.new(1, 0, 0, 40)
	brightNightStrengthRow.Position = UDim2.new(0, 0, 0, 82)
	brightNightStrengthRow.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	brightNightStrengthRow.Text = "  Bright Night Strength"
	brightNightStrengthRow.TextColor3 = Color3.fromRGB(210, 212, 220)
	brightNightStrengthRow.TextSize = 15
	brightNightStrengthRow.Font = Enum.Font.GothamBold
	brightNightStrengthRow.TextXAlignment = Enum.TextXAlignment.Left
	brightNightStrengthRow.Parent = worldContent

	local brightNightStrengthInput = Instance.new("TextBox")
	brightNightStrengthInput.Size = UDim2.new(0, 80, 0, 26)
	brightNightStrengthInput.Position = UDim2.new(1, -96, 0.5, -13)
	brightNightStrengthInput.BackgroundColor3 = Color3.fromRGB(16, 16, 22)
	brightNightStrengthInput.Text = "1.00"
	brightNightStrengthInput.TextColor3 = Color3.fromRGB(220, 222, 230)
	brightNightStrengthInput.TextSize = 14
	brightNightStrengthInput.Font = Enum.Font.GothamBold
	brightNightStrengthInput.PlaceholderText = "1.00"
	brightNightStrengthInput.ClearTextOnFocus = false
	brightNightStrengthInput.Parent = brightNightStrengthRow

	do
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = brightNightStrengthInput

		local s = Instance.new("UIStroke")
		s.Color = Color3.fromRGB(55, 55, 70)
		s.Thickness = 1.2
		s.Parent = brightNightStrengthInput
	end

	brightNightStrengthInput.Focused:Connect(function()
		tweenUI(brightNightStrengthInput, 0.1, {BackgroundColor3 = Color3.fromRGB(24, 24, 32)})
	end)

	brightNightStrengthInput.FocusLost:Connect(function()
		tweenUI(brightNightStrengthInput, 0.12, {BackgroundColor3 = Color3.fromRGB(16, 16, 22)})
		local newStrength = tonumber(brightNightStrengthInput.Text)
		if newStrength then
			newStrength = math.clamp(newStrength, 0.6, 2.4)
			worldBrightNightStrength = newStrength
			brightNightStrengthInput.Text = string.format("%.2f", newStrength)
		else
			brightNightStrengthInput.Text = "1.00"
			worldBrightNightStrength = 1
		end

		if worldFx then
			worldFx.brightNightStrength = worldBrightNightStrength
			if worldFx.customSky then
				applyCustomSky()
			elseif worldFx.brightNight then
				applyWorldFx()
			else
				updateWorldFxStatus()
			end
		end
	end)

	-- Custom Sky toggle
	local customSkyToggle = Instance.new("TextButton")
	customSkyToggle.Size = UDim2.new(1, 0, 0, 40)
	customSkyToggle.Position = UDim2.new(0, 0, 0, 126)
	customSkyToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	customSkyToggle.Text = "  Custom Sky"
	customSkyToggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	customSkyToggle.TextSize = 15
	customSkyToggle.Font = Enum.Font.GothamBold
	customSkyToggle.TextXAlignment = Enum.TextXAlignment.Left
	customSkyToggle.Parent = worldContent

	local setCustomSkyCheck = createModernCheckbox(customSkyToggle)
	setCustomSkyCheck(false)

	-- Sky Image preset selector row
	local skyUI = {}
	do
		local skyImageRow = Instance.new("Frame")
		skyImageRow.Size = UDim2.new(1, 0, 0, 40)
		skyImageRow.Position = UDim2.new(0, 0, 0, 170)
		skyImageRow.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
		skyImageRow.Parent = worldContent
		skyUI.imageRow = skyImageRow
	end

	skyUI.imageIndex = 1
	skyUI.presets = {
		{ name = "Solid Color" },
		{ name = "Game Default" },
		{ name = "Nebula",      bk="rbxassetid://159454286", dn="rbxassetid://159454288", ft="rbxassetid://159454300", lf="rbxassetid://159454293", rt="rbxassetid://159454299", up="rbxassetid://159454296" },
		{ name = "Night Stars", bk="rbxassetid://12064107",  dn="rbxassetid://12064107",  ft="rbxassetid://12064115",  lf="rbxassetid://12064121",  rt="rbxassetid://12064107",  up="rbxassetid://12064131" },
		{ name = "Cloudy",      bk="rbxassetid://6444884337", dn="rbxassetid://6444884785", ft="rbxassetid://6444884337", lf="rbxassetid://6444884337", rt="rbxassetid://6444884337", up="rbxassetid://6412503613" },
		{ name = "Space",       bk="rbxassetid://6060545541", dn="rbxassetid://6060545541", ft="rbxassetid://6060545541", lf="rbxassetid://6060545541", rt="rbxassetid://6060545541", up="rbxassetid://6060545541" },
	}
	for i = 3, #skyUI.presets do
		if skyUI.presets[i].bk or skyUI.presets[i].dn or skyUI.presets[i].ft or skyUI.presets[i].lf or skyUI.presets[i].rt or skyUI.presets[i].up then
			skyUI.presets[i].bk = skyUI.presets[i].bk or skyUI.presets[i].dn or skyUI.presets[i].ft or skyUI.presets[i].lf or skyUI.presets[i].rt or skyUI.presets[i].up
			skyUI.presets[i].dn = skyUI.presets[i].dn or skyUI.presets[i].bk
			skyUI.presets[i].ft = skyUI.presets[i].ft or skyUI.presets[i].bk
			skyUI.presets[i].lf = skyUI.presets[i].lf or skyUI.presets[i].bk
			skyUI.presets[i].rt = skyUI.presets[i].rt or skyUI.presets[i].bk
			skyUI.presets[i].up = skyUI.presets[i].up or skyUI.presets[i].bk
		end
	end

	-- Capture the game's existing Sky textures for the "Game Default" preset
	do
		local existingSky = Lighting:FindFirstChildOfClass("Sky")
		if existingSky then
			skyUI.presets[2] = {
				name = "Game Default",
				bk = existingSky.SkyboxBk,
				dn = existingSky.SkyboxDn,
				ft = existingSky.SkyboxFt,
				lf = existingSky.SkyboxLf,
				rt = existingSky.SkyboxRt,
				up = existingSky.SkyboxUp,
			}
			if not skyUI.presets[2].bk then skyUI.presets[2].bk = skyUI.presets[2].dn or skyUI.presets[2].ft or skyUI.presets[2].lf or skyUI.presets[2].rt or skyUI.presets[2].up end
			if not skyUI.presets[2].dn then skyUI.presets[2].dn = skyUI.presets[2].bk end
			if not skyUI.presets[2].ft then skyUI.presets[2].ft = skyUI.presets[2].bk end
			if not skyUI.presets[2].lf then skyUI.presets[2].lf = skyUI.presets[2].bk end
			if not skyUI.presets[2].rt then skyUI.presets[2].rt = skyUI.presets[2].bk end
			if not skyUI.presets[2].up then skyUI.presets[2].up = skyUI.presets[2].bk end
		end
	end

	do
		local skyImageLabel = Instance.new("TextLabel")
		skyImageLabel.Size = UDim2.new(0.5, -8, 1, 0)
		skyImageLabel.Position = UDim2.new(0, 8, 0, 0)
		skyImageLabel.BackgroundTransparency = 1
		skyImageLabel.Text = "  Sky: Solid Color"
		skyImageLabel.TextColor3 = Color3.fromRGB(180, 182, 195)
		skyImageLabel.TextSize = 13
		skyImageLabel.Font = Enum.Font.GothamBold
		skyImageLabel.TextXAlignment = Enum.TextXAlignment.Left
		skyImageLabel.TextTruncate = Enum.TextTruncate.AtEnd
		skyImageLabel.Parent = skyUI.imageRow
		skyUI.imageLabel = skyImageLabel
	end

	do
		local prevBtn = Instance.new("TextButton")
		prevBtn.Size = UDim2.new(0, 34, 0, 28)
		prevBtn.Position = UDim2.new(1, -86, 0.5, -14)
		prevBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 42)
		prevBtn.Text = "<"
		prevBtn.TextColor3 = Color3.fromRGB(200, 200, 215)
		prevBtn.TextSize = 16
		prevBtn.Font = Enum.Font.GothamBold
		prevBtn.Parent = skyUI.imageRow
		local pc = Instance.new("UICorner")
		pc.CornerRadius = UDim.new(0, 6)
		pc.Parent = prevBtn

		local nextBtn = Instance.new("TextButton")
		nextBtn.Size = UDim2.new(0, 34, 0, 28)
		nextBtn.Position = UDim2.new(1, -48, 0.5, -14)
		nextBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 42)
		nextBtn.Text = ">"
		nextBtn.TextColor3 = Color3.fromRGB(200, 200, 215)
		nextBtn.TextSize = 16
		nextBtn.Font = Enum.Font.GothamBold
		nextBtn.Parent = skyUI.imageRow
		local nc = Instance.new("UICorner")
		nc.CornerRadius = UDim.new(0, 6)
		nc.Parent = nextBtn

		prevBtn.MouseButton1Click:Connect(function()
			skyUI.imageIndex = skyUI.imageIndex - 1
			if skyUI.imageIndex < 1 then skyUI.imageIndex = #skyUI.presets end
			skyUI.imageLabel.Text = "  Sky: " .. skyUI.presets[skyUI.imageIndex].name
			if worldFx.customSky then skyUI.applyFn() end
		end)
		nextBtn.MouseButton1Click:Connect(function()
			skyUI.imageIndex = skyUI.imageIndex + 1
			if skyUI.imageIndex > #skyUI.presets then skyUI.imageIndex = 1 end
			skyUI.imageLabel.Text = "  Sky: " .. skyUI.presets[skyUI.imageIndex].name
			if worldFx.customSky then skyUI.applyFn() end
		end)
	end

	-- ============ RGB COLOR PICKER ============
	-- Hue/Saturation gradient canvas + Brightness slider + R/G/B fields + preview

	do
		local skyPickerFrame = Instance.new("Frame")
		skyPickerFrame.Size = UDim2.new(1, -16, 0, 130)
		skyPickerFrame.Position = UDim2.new(0, 8, 0, 216)
		skyPickerFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
		skyPickerFrame.Parent = worldContent
		skyUI.pickerFrame = skyPickerFrame
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = skyPickerFrame
		local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(38, 38, 52); s.Thickness = 1; s.Parent = skyPickerFrame
	end

	-- ============ PICKER CANVAS + CONTROLS ============
	do
		-- Hue-saturation canvas
		local hsCanvas = Instance.new("ImageButton")
		hsCanvas.Size = UDim2.new(0, 130, 0, 100)
		hsCanvas.Position = UDim2.new(0, 8, 0, 8)
		hsCanvas.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
		hsCanvas.AutoButtonColor = false
		hsCanvas.Parent = skyUI.pickerFrame
		skyUI.hsCanvas = hsCanvas
		local hsc = Instance.new("UICorner"); hsc.CornerRadius = UDim.new(0, 4); hsc.Parent = hsCanvas

		-- White-to-transparent gradient (horizontal, for saturation)
		local satOverlay = Instance.new("Frame")
		satOverlay.Size = UDim2.new(1, 0, 1, 0)
		satOverlay.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		satOverlay.BorderSizePixel = 0
		satOverlay.ZIndex = 2
		satOverlay.Parent = hsCanvas
		Instance.new("UICorner", satOverlay).CornerRadius = UDim.new(0, 4)
		local sg = Instance.new("UIGradient")
		sg.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(1, 1, 1))
		sg.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1)})
		sg.Parent = satOverlay

		-- Black-to-transparent gradient (vertical, for value/brightness)
		local valOverlay = Instance.new("Frame")
		valOverlay.Size = UDim2.new(1, 0, 1, 0)
		valOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		valOverlay.BorderSizePixel = 0
		valOverlay.ZIndex = 3
		valOverlay.Parent = hsCanvas
		Instance.new("UICorner", valOverlay).CornerRadius = UDim.new(0, 4)
		local vg = Instance.new("UIGradient")
		vg.Color = ColorSequence.new(Color3.new(0, 0, 0), Color3.new(0, 0, 0))
		vg.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0)})
		vg.Rotation = 90
		vg.Parent = valOverlay

		-- SV cursor (small circle indicator)
		local svCursor = Instance.new("Frame")
		svCursor.Size = UDim2.new(0, 10, 0, 10)
		svCursor.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		svCursor.BackgroundTransparency = 0.15
		svCursor.ZIndex = 5
		svCursor.Parent = hsCanvas
		skyUI.svCursor = svCursor
		Instance.new("UICorner", svCursor).CornerRadius = UDim.new(1, 0)
		local svs = Instance.new("UIStroke"); svs.Color = Color3.fromRGB(0, 0, 0); svs.Thickness = 1.5; svs.Parent = svCursor

		-- Hue slider (vertical rainbow bar)
		local hueBar = Instance.new("ImageButton")
		hueBar.Size = UDim2.new(0, 18, 0, 100)
		hueBar.Position = UDim2.new(0, 146, 0, 8)
		hueBar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		hueBar.AutoButtonColor = false
		hueBar.Parent = skyUI.pickerFrame
		skyUI.hueBar = hueBar
		Instance.new("UICorner", hueBar).CornerRadius = UDim.new(0, 4)
		local hg = Instance.new("UIGradient")
		hg.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0,     Color3.fromRGB(255, 0, 0)),
			ColorSequenceKeypoint.new(0.167, Color3.fromRGB(255, 255, 0)),
			ColorSequenceKeypoint.new(0.333, Color3.fromRGB(0, 255, 0)),
			ColorSequenceKeypoint.new(0.5,   Color3.fromRGB(0, 255, 255)),
			ColorSequenceKeypoint.new(0.667, Color3.fromRGB(0, 0, 255)),
			ColorSequenceKeypoint.new(0.833, Color3.fromRGB(255, 0, 255)),
			ColorSequenceKeypoint.new(1,     Color3.fromRGB(255, 0, 0)),
		})
		hg.Rotation = 90
		hg.Parent = hueBar

		-- Hue cursor
		local hueCursor = Instance.new("Frame")
		hueCursor.Size = UDim2.new(1, 4, 0, 4)
		hueCursor.Position = UDim2.new(0, -2, 0, 0)
		hueCursor.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		hueCursor.ZIndex = 5
		hueCursor.Parent = hueBar
		skyUI.hueCursor = hueCursor
		Instance.new("UICorner", hueCursor).CornerRadius = UDim.new(1, 0)
		local hcs = Instance.new("UIStroke"); hcs.Color = Color3.fromRGB(0, 0, 0); hcs.Thickness = 1; hcs.Parent = hueCursor

		-- Color preview
		local skyPreview = Instance.new("Frame")
		skyPreview.Size = UDim2.new(0, 100, 0, 40)
		skyPreview.Position = UDim2.new(0, 174, 0, 8)
		skyPreview.BackgroundColor3 = Color3.fromRGB(135, 170, 220)
		skyPreview.Parent = skyUI.pickerFrame
		skyUI.preview = skyPreview
		Instance.new("UICorner", skyPreview).CornerRadius = UDim.new(0, 6)
		local ps = Instance.new("UIStroke"); ps.Color = Color3.fromRGB(55, 55, 70); ps.Thickness = 1; ps.Parent = skyPreview
	end

	local skyInputs = {}
	do
		local labels = {"R", "G", "B"}
		local defaults = {135, 170, 220}
		local yPositions = {54, 74, 94}
		local keys = {"r", "g", "b"}
		for i = 1, 3 do
			local lbl = Instance.new("TextLabel")
			lbl.Size = UDim2.new(0, 16, 0, 18)
			lbl.Position = UDim2.new(0, 174, 0, yPositions[i])
			lbl.BackgroundTransparency = 1
			lbl.Text = labels[i]
			lbl.TextColor3 = Color3.fromRGB(120, 122, 140)
			lbl.TextSize = 11
			lbl.Font = Enum.Font.GothamBold
			lbl.Parent = skyUI.pickerFrame

			local input = Instance.new("TextBox")
			input.Size = UDim2.new(0, 62, 0, 18)
			input.Position = UDim2.new(0, 192, 0, yPositions[i])
			input.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
			input.Text = tostring(defaults[i])
			input.TextColor3 = Color3.fromRGB(220, 222, 230)
			input.TextSize = 12
			input.Font = Enum.Font.GothamBold
			input.ClearTextOnFocus = false
			input.Parent = skyUI.pickerFrame
			local ic = Instance.new("UICorner"); ic.CornerRadius = UDim.new(0, 4); ic.Parent = input
			local is = Instance.new("UIStroke"); is.Color = Color3.fromRGB(48, 48, 62); is.Thickness = 1; is.Parent = input
			skyInputs[keys[i]] = input
		end
	end

	-- Hex input row
	do
		local hexLbl = Instance.new("TextLabel")
		hexLbl.Size = UDim2.new(0, 16, 0, 18)
		hexLbl.Position = UDim2.new(0, 174, 0, 114)
		hexLbl.BackgroundTransparency = 1
		hexLbl.Text = "#"
		hexLbl.TextColor3 = Color3.fromRGB(120, 122, 140)
		hexLbl.TextSize = 11
		hexLbl.Font = Enum.Font.GothamBold
		hexLbl.Parent = skyUI.pickerFrame

		local hexInput = Instance.new("TextBox")
		hexInput.Size = UDim2.new(0, 62, 0, 18)
		hexInput.Position = UDim2.new(0, 192, 0, 114)
		hexInput.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
		hexInput.Text = "87AADC"
		hexInput.TextColor3 = Color3.fromRGB(220, 222, 230)
		hexInput.TextSize = 12
		hexInput.Font = Enum.Font.GothamBold
		hexInput.ClearTextOnFocus = false
		hexInput.Parent = skyUI.pickerFrame
		local hc = Instance.new("UICorner"); hc.CornerRadius = UDim.new(0, 4); hc.Parent = hexInput
		local hs = Instance.new("UIStroke"); hs.Color = Color3.fromRGB(48, 48, 62); hs.Thickness = 1; hs.Parent = hexInput
		skyInputs.hex = hexInput
	end

	-- Sky status label
	local skyStatus = Instance.new("TextLabel")
	skyStatus.Size = UDim2.new(1, 0, 0, 22)
	skyStatus.Position = UDim2.new(0, 0, 0, 352)
	skyStatus.BackgroundTransparency = 1
	skyStatus.Text = "Sky: Default"
	skyStatus.TextColor3 = Color3.fromRGB(100, 105, 120)
	skyStatus.TextSize = 12
	skyStatus.Font = Enum.Font.GothamMedium
	skyStatus.TextXAlignment = Enum.TextXAlignment.Left
	skyStatus.Parent = worldContent

	-- =============== COMBAT CONTROLS ===============
	local aimToggle = Instance.new("TextButton")
	aimToggle.Size = UDim2.new(1, 0, 0, 40)
	aimToggle.Position = UDim2.new(0, 0, 0, 6)
	aimToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	aimToggle.Text = "  Aimbot"
	aimToggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	aimToggle.TextSize = 15
	aimToggle.Font = Enum.Font.GothamBold
	aimToggle.TextXAlignment = Enum.TextXAlignment.Left
	aimToggle.Parent = combatContent

	local setAimCheck = createModernCheckbox(aimToggle)
	setAimCheck(false)

	-- Fire Rate toggle
	local fireRateToggle = Instance.new("TextButton")
	fireRateToggle.Size = UDim2.new(1, 0, 0, 40)
	fireRateToggle.Position = UDim2.new(0, 0, 0, 52)
	fireRateToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	fireRateToggle.Text = "  Fire Rate"
	fireRateToggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	fireRateToggle.TextSize = 15
	fireRateToggle.Font = Enum.Font.GothamBold
	fireRateToggle.TextXAlignment = Enum.TextXAlignment.Left
	fireRateToggle.Parent = combatContent

	local setFireRateCheck = createModernCheckbox(fireRateToggle)
	setFireRateCheck(false)

	-- Always Automatic toggle
	local alwaysAutoToggle = Instance.new("TextButton")
	alwaysAutoToggle.Size = UDim2.new(1, 0, 0, 40)
	alwaysAutoToggle.Position = UDim2.new(0, 0, 0, 98)
	alwaysAutoToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	alwaysAutoToggle.Text = "  Always Automatic"
	alwaysAutoToggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	alwaysAutoToggle.TextSize = 15
	alwaysAutoToggle.Font = Enum.Font.GothamBold
	alwaysAutoToggle.TextXAlignment = Enum.TextXAlignment.Left
	alwaysAutoToggle.Parent = combatContent

	local setAlwaysAutoCheck = createModernCheckbox(alwaysAutoToggle)
	setAlwaysAutoCheck(false)

	alwaysAutoToggle.MouseEnter:Connect(function()
		tweenUI(alwaysAutoToggle, {BackgroundColor3 = Color3.fromRGB(30, 30, 40)})
	end)
	alwaysAutoToggle.MouseLeave:Connect(function()
		tweenUI(alwaysAutoToggle, {BackgroundColor3 = Color3.fromRGB(22, 22, 30)})
	end)

	-- Become Flash toggle
	local flashToggle = Instance.new("TextButton")
	flashToggle.Size = UDim2.new(1, 0, 0, 40)
	flashToggle.Position = UDim2.new(0, 0, 0, 144)
	flashToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	flashToggle.Text = "  Become Flash"
	flashToggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	flashToggle.TextSize = 15
	flashToggle.Font = Enum.Font.GothamBold
	flashToggle.TextXAlignment = Enum.TextXAlignment.Left
	flashToggle.Parent = combatContent

	local setFlashCheck = createModernCheckbox(flashToggle)
	setFlashCheck(false)

	-- Long Melee toggle
	local longMeleeToggle = Instance.new("TextButton")
	longMeleeToggle.Size = UDim2.new(1, 0, 0, 40)
	longMeleeToggle.Position = UDim2.new(0, 0, 0, 190)
	longMeleeToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	longMeleeToggle.Text = "  Long Melee & Bypass"
	longMeleeToggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	longMeleeToggle.TextSize = 15
	longMeleeToggle.Font = Enum.Font.GothamBold
	longMeleeToggle.TextXAlignment = Enum.TextXAlignment.Left
	longMeleeToggle.Parent = combatContent

	local setLongMeleeCheck = createModernCheckbox(longMeleeToggle)
	setLongMeleeCheck(false)

	-- No Recoil toggle
	local noRecoilToggle = Instance.new("TextButton")
	noRecoilToggle.Size = UDim2.new(1, 0, 0, 40)
	noRecoilToggle.Position = UDim2.new(0, 0, 0, 236)
	noRecoilToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	noRecoilToggle.Text = "  No Recoil"
	noRecoilToggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	noRecoilToggle.TextSize = 15
	noRecoilToggle.Font = Enum.Font.GothamBold
	noRecoilToggle.TextXAlignment = Enum.TextXAlignment.Left
	noRecoilToggle.ZIndex = 1
	noRecoilToggle.Parent = combatContent

	local setNoRecoilCheck = createModernCheckbox(noRecoilToggle)
	setNoRecoilCheck(false)

	noRecoilToggle.MouseButton1Click:Connect(function()
		local success, result = safeExecute(function()
			noRecoilState.enabled = not noRecoilState.enabled
			setNoRecoilCheck(noRecoilState.enabled)
			if noRecoilState.enabled then
				local isMobileDevice = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
				noRecoilState.maxPerTick = isMobileDevice and 110 or 230
				noRecoilState.baseApplyInterval = isMobileDevice and 0.12 or 0.08
				noRecoilState.applyInterval = noRecoilState.baseApplyInterval
				noRecoilState.rescanInterval = isMobileDevice and 1.75 or 1.25
				noRecoilState.avgDt = 0
				noRecoilState.lastTickTime = 0
				noRecoilState.lastRescanTime = 0

				-- Apply to ReplicatedStorage Weapons (primary location)
				local weaponsFolder = ReplicatedStorage:FindFirstChild("Weapons")
				if weaponsFolder then
					applyNoRecoilToRoot(weaponsFolder)
				else
					logError("NO_RECOIL", "Weapons folder not found in ReplicatedStorage", nil, {path = "ReplicatedStorage.Weapons"})
				end

				-- Apply to Arsenal data if available (for Arsenal game)
				if ArsenalData then
					applyNoRecoilToRoot(ArsenalData)
				else
					logCommand("NO_RECOIL", false, "ArsenalData not available", 0)
				end

				-- Apply to player's current tools
				local player = Players.LocalPlayer
				if player and player.Character then
					applyNoRecoilToRoot(player.Character)
				else
					logError("NO_RECOIL", "Player character not available", nil, {player = player and player.Name})
				end

				local backpack = player and player:FindFirstChildOfClass("Backpack")
				if backpack then
					applyNoRecoilToRoot(backpack)
				else
					logCommand("NO_RECOIL", false, "Player backpack not available", 0)
				end

				-- Lightweight adaptive loop: chunked application over indexed recoil values.
				noRecoilState.aggressiveConnection = RunService.Heartbeat:Connect(function(dt)
					if not noRecoilState.enabled then return end
					applyNoRecoilTick(dt)
				end)

				-- Hook into humanoid/camera for direct recoil prevention
				local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					noRecoilState.humanoidHook = humanoid:GetPropertyChangedSignal("CameraOffset"):Connect(function()
						if noRecoilState.enabled then
							humanoid.CameraOffset = Vector3.new(0, 0, 0)
						end
					end)
					-- Also set it immediately
					humanoid.CameraOffset = Vector3.new(0, 0, 0)
					logCommand("NO_RECOIL", true, "Humanoid camera offset hook established", 0)
				end

				-- Hook into tool activation for weapon-specific recoil
				local function hookToolActivation(tool)
					if tool and noRecoilState.enabled then
						local activationConnection = tool.Activated:Connect(function()
							if noRecoilState.enabled then
								-- Immediately apply no recoil when tool is activated
								local success, result = pcall(function() applyNoRecoilToRoot(tool) end)
								if success then
									logCommand("NO_RECOIL", true, "Applied to activated tool: " .. tool.Name, 0)
								end
							end
						end)
						noRecoilState.toolHooks = noRecoilState.toolHooks or {}
						table.insert(noRecoilState.toolHooks, activationConnection)
					end
				end

				-- Hook existing tools
				local backpackRef = player and player:FindFirstChildOfClass("Backpack")
				if backpackRef then
					for _, tool in ipairs(backpackRef:GetChildren()) do
						if tool:IsA("Tool") then
							hookToolActivation(tool)
							applyNoRecoilToRoot(tool)
						end
					end
				end

				-- Hook for tool equipping/unequipping
				if backpackRef then
					noRecoilState.backpackHook = backpackRef.ChildAdded:Connect(function(child)
						if child:IsA("Tool") and noRecoilState.enabled then
							hookToolActivation(child)
							applyNoRecoilToRoot(child)
						end
					end)
				end

				-- Hook for character tool changes (equipping)
				local characterRef = player and player.Character
				if characterRef then
					noRecoilState.characterHook = characterRef.ChildAdded:Connect(function(child)
						if child:IsA("Tool") and noRecoilState.enabled then
							applyNoRecoilToRoot(child)
						end
					end)
				end

				logCommand("NO_RECOIL", true, string.format("Enabled optimized monitor (%d tracked values)", #noRecoilState.trackedValues), 0)
			else
				logCommand("NO_RECOIL", true, "Disabling NO RECOIL", 0)
				-- Restore original values
				local restoreCount = 0
				for desc, origValue in pairs(noRecoilState.originalValues) do
					local success, result = pcall(function() desc.Value = origValue end)
					if success then
						restoreCount = restoreCount + 1
					else
						logError("NO_RECOIL", "Failed to restore value", nil, {desc = desc.Name, error = result})
					end
				end
				noRecoilState.originalValues = {}

				-- Disconnect all connections
				if noRecoilState.connection then
					noRecoilState.connection:Disconnect()
					noRecoilState.connection = nil
				end
				if noRecoilState.aggressiveConnection then
					noRecoilState.aggressiveConnection:Disconnect()
					noRecoilState.aggressiveConnection = nil
				end
				if noRecoilState.cameraHook then
					noRecoilState.cameraHook:Disconnect()
					noRecoilState.cameraHook = nil
				end
				if noRecoilState.humanoidHook then
					noRecoilState.humanoidHook:Disconnect()
					noRecoilState.humanoidHook = nil
				end
				if noRecoilState.backpackHook then
					noRecoilState.backpackHook:Disconnect()
					noRecoilState.backpackHook = nil
				end
				if noRecoilState.characterHook then
					noRecoilState.characterHook:Disconnect()
					noRecoilState.characterHook = nil
				end
				if noRecoilState.toolHooks then
					for _, hook in ipairs(noRecoilState.toolHooks) do
						hook:Disconnect()
					end
					noRecoilState.toolHooks = {}
				end

				clearNoRecoilTracking()

				logCommand("NO_RECOIL", true, string.format("Disabled, restored %d values", restoreCount), 0)
			end
		end, "NO_RECOIL_TOGGLE")

		if not success then
			logError("NO_RECOIL", "Toggle operation failed", nil, result)
			-- Keep the visual state aligned with the user's toggle action.
			setNoRecoilCheck(noRecoilState.enabled)
		end
	end)

	noRecoilToggle.MouseEnter:Connect(function()
		tweenUI(noRecoilToggle, {BackgroundColor3 = Color3.fromRGB(30, 30, 40)})
	end)
	noRecoilToggle.MouseLeave:Connect(function()
		tweenUI(noRecoilToggle, {BackgroundColor3 = Color3.fromRGB(22, 22, 30)})
	end)

	-- Fly toggle
	local flyToggle = Instance.new("TextButton")
	flyToggle.Size = UDim2.new(1, 0, 0, 40)
	flyToggle.Position = UDim2.new(0, 0, 0, 282)
	flyToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	flyToggle.Text = "  Fly"
	flyToggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	flyToggle.TextSize = 15
	flyToggle.Font = Enum.Font.GothamBold
	flyToggle.TextXAlignment = Enum.TextXAlignment.Left
	flyToggle.Parent = combatContent

	local setFlyCheck = createModernCheckbox(flyToggle)
	setFlyCheck(false)

	local killAllToggle = Instance.new("TextButton")
	killAllToggle.Size = UDim2.new(1, 0, 0, 40)
	killAllToggle.Position = UDim2.new(0, 0, 0, 328)
	killAllToggle.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	killAllToggle.Text = "  Kill All"
	killAllToggle.TextColor3 = Color3.fromRGB(210, 212, 220)
	killAllToggle.TextSize = 15
	killAllToggle.Font = Enum.Font.GothamBold
	killAllToggle.TextXAlignment = Enum.TextXAlignment.Left
	killAllToggle.Parent = combatContent

	local setKillAllCheck = createModernCheckbox(killAllToggle)
	setKillAllCheck(false)

	local function createSettingsNumberInputRow(layoutOrder, labelText, initialText, placeholderText, onCommit)
		local rowLabel = Instance.new("TextLabel")
		rowLabel.Size = UDim2.new(1, 0, 0, 40)
		rowLabel.LayoutOrder = layoutOrder
		rowLabel.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
		rowLabel.Text = "  " .. labelText
		rowLabel.TextColor3 = Color3.fromRGB(214, 218, 230)
		rowLabel.TextSize = 14
		rowLabel.Font = Enum.Font.GothamBold
		rowLabel.TextXAlignment = Enum.TextXAlignment.Left
		rowLabel.Parent = settingsContent

		local input = Instance.new("TextBox")
		input.Size = UDim2.new(0, 80, 0, 26)
		input.Position = UDim2.new(1, -96, 0.5, -13)
		input.BackgroundColor3 = Color3.fromRGB(16, 16, 22)
		input.Text = initialText
		input.TextColor3 = Color3.fromRGB(226, 228, 236)
		input.TextSize = 14
		input.Font = Enum.Font.GothamBold
		input.PlaceholderText = placeholderText
		input.Parent = rowLabel

		input.Focused:Connect(function()
			tweenUI(input, 0.1, {BackgroundColor3 = Color3.fromRGB(24, 24, 32)})
		end)

		do
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, 8)
			c.Parent = input

			local s = Instance.new("UIStroke")
			s.Color = Color3.fromRGB(55, 55, 70)
			s.Thickness = 1.2
			s.Transparency = 0.22
			s.Parent = input
		end

		input.FocusLost:Connect(function()
			tweenUI(input, 0.12, {BackgroundColor3 = Color3.fromRGB(16, 16, 22)})
			local normalized = onCommit(input.Text)
			input.Text = normalized
		end)

		return rowLabel, input
	end

	-- Aimbot FOV setting
	createSettingsNumberInputRow(
		1,
		"Aimbot FOV",
		tostring(aimbotFOV),
		"120",
		function(rawText)
			local newFOV = tonumber(rawText)
			if newFOV and newFOV > 0 and newFOV <= 1000 then
				aimbotFOV = newFOV
			end

			local camera = workspace.CurrentCamera
			local viewportSize = camera and camera.ViewportSize or Vector2.new(0, 0)
			local center = Vector2.new(viewportSize.X / 2, viewportSize.Y / 2)
			if aimDraw.fovCircle then
				aimDraw.fovCircle.Position = center
				aimDraw.fovCircle.Radius = aimbotFOV
			end
			return tostring(aimbotFOV)
		end
	)

	-- Fire Rate interval setting (seconds between shots)
	createSettingsNumberInputRow(
		2,
		"Fire Rate Interval (sec)",
		string.format("%.3f", fireRateState.shootRate),
		"0.008",
		function(rawText)
			local newValue = tonumber(rawText)
			if newValue and newValue >= 0.001 and newValue <= 0.5 then
				fireRateState.shootRate = newValue
			end
			return string.format("%.3f", fireRateState.shootRate)
		end
	)

	createSettingsNumberInputRow(
		3,
		"Crosshair Size",
		tostring(crosshairSettings.size),
		"8",
		function(rawText)
			local newValue = tonumber(rawText)
			if newValue then
				crosshairSettings.size = math.clamp(math.floor(newValue + 0.5), 2, 40)
			end
			return tostring(crosshairSettings.size)
		end
	)

	createSettingsNumberInputRow(
		4,
		"Crosshair Thickness",
		string.format("%.1f", crosshairSettings.thickness),
		"2.0",
		function(rawText)
			local newValue = tonumber(rawText)
			if newValue then
				crosshairSettings.thickness = math.clamp(newValue, 0.5, 10)
			end
			return string.format("%.1f", crosshairSettings.thickness)
		end
	)

	createSettingsNumberInputRow(
		5,
		"Crosshair Glow Thickness",
		string.format("%.1f", crosshairSettings.glowThickness),
		"4.0",
		function(rawText)
			local newValue = tonumber(rawText)
			if newValue then
				crosshairSettings.glowThickness = math.clamp(newValue, 1, 14)
			end
			return string.format("%.1f", crosshairSettings.glowThickness)
		end
	)

	createSettingsNumberInputRow(
		6,
		"Crosshair Opacity",
		string.format("%.2f", crosshairSettings.opacity),
		"0.80",
		function(rawText)
			local newValue = tonumber(rawText)
			if newValue then
				crosshairSettings.opacity = math.clamp(newValue, 0, 1)
			end
			return string.format("%.2f", crosshairSettings.opacity)
		end
	)

	createSettingsNumberInputRow(
		7,
		"Crosshair Glow Opacity",
		string.format("%.2f", crosshairSettings.glowOpacity),
		"0.20",
		function(rawText)
			local newValue = tonumber(rawText)
			if newValue then
				crosshairSettings.glowOpacity = math.clamp(newValue, 0, 1)
			end
			return string.format("%.2f", crosshairSettings.glowOpacity)
		end
	)

	-- =============== LOG VIEW ACTIONS ===============
	do
	local viewErrorLogButton = Instance.new("TextButton")
	viewErrorLogButton.Size = UDim2.new(1, 0, 0, 40)
	viewErrorLogButton.Position = UDim2.new(0, 0, 0, 0)
	viewErrorLogButton.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
	viewErrorLogButton.Text = "  View Error Log"
	viewErrorLogButton.TextColor3 = Color3.fromRGB(210, 212, 220)
	viewErrorLogButton.TextSize = 15
	viewErrorLogButton.Font = Enum.Font.GothamBold
	viewErrorLogButton.TextXAlignment = Enum.TextXAlignment.Left
	viewErrorLogButton.LayoutOrder = 100
	viewErrorLogButton.Parent = settingsContent

	local errorLogPanel = Instance.new("Frame")
	errorLogPanel.Size = UDim2.new(1, 0, 0, 252)
	errorLogPanel.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
	errorLogPanel.Visible = false
	errorLogPanel.LayoutOrder = 101
	errorLogPanel.Parent = settingsContent

	local errorLogPanelCorner = Instance.new("UICorner")
	errorLogPanelCorner.CornerRadius = UDim.new(0, 8)
	errorLogPanelCorner.Parent = errorLogPanel

	local errorLogPanelStroke = Instance.new("UIStroke")
	errorLogPanelStroke.Color = Color3.fromRGB(40, 42, 55)
	errorLogPanelStroke.Thickness = 1
	errorLogPanelStroke.Transparency = 0.2
	errorLogPanelStroke.Parent = errorLogPanel

	local errorLogHeader = Instance.new("Frame")
	errorLogHeader.Size = UDim2.new(1, -12, 0, 34)
	errorLogHeader.Position = UDim2.new(0, 6, 0, 6)
	errorLogHeader.BackgroundTransparency = 1
	errorLogHeader.Parent = errorLogPanel

	local errorLogTitle = Instance.new("TextLabel")
	errorLogTitle.Size = UDim2.new(1, -132, 1, 0)
	errorLogTitle.BackgroundTransparency = 1
	errorLogTitle.Text = "Current Error Log"
	errorLogTitle.TextColor3 = Color3.fromRGB(235, 238, 245)
	errorLogTitle.TextSize = 14
	errorLogTitle.Font = Enum.Font.GothamBold
	errorLogTitle.TextXAlignment = Enum.TextXAlignment.Left
	errorLogTitle.Parent = errorLogHeader

	local errorLogCount = Instance.new("TextLabel")
	errorLogCount.Size = UDim2.new(0, 92, 1, 0)
	errorLogCount.Position = UDim2.new(1, -224, 0, 0)
	errorLogCount.BackgroundTransparency = 1
	errorLogCount.Text = "0 errors"
	errorLogCount.TextColor3 = Color3.fromRGB(125, 130, 145)
	errorLogCount.TextSize = 12
	errorLogCount.Font = Enum.Font.GothamMedium
	errorLogCount.TextXAlignment = Enum.TextXAlignment.Right
	errorLogCount.Parent = errorLogHeader

	local copyErrorLogButton = Instance.new("TextButton")
	copyErrorLogButton.Size = UDim2.new(0, 118, 0, 26)
	copyErrorLogButton.Position = UDim2.new(1, -118, 0.5, -13)
	copyErrorLogButton.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
	copyErrorLogButton.Text = "Copy Output"
	copyErrorLogButton.TextColor3 = Color3.fromRGB(224, 228, 236)
	copyErrorLogButton.TextSize = 12
	copyErrorLogButton.Font = Enum.Font.GothamBold
	copyErrorLogButton.Parent = errorLogHeader

	local copyErrorLogCorner = Instance.new("UICorner")
	copyErrorLogCorner.CornerRadius = UDim.new(0, 6)
	copyErrorLogCorner.Parent = copyErrorLogButton

	local copyErrorLogStroke = Instance.new("UIStroke")
	copyErrorLogStroke.Color = Color3.fromRGB(64, 76, 108)
	copyErrorLogStroke.Thickness = 1
	copyErrorLogStroke.Transparency = 0.18
	copyErrorLogStroke.Parent = copyErrorLogButton

	local errorLogHint = Instance.new("TextLabel")
	errorLogHint.Size = UDim2.new(1, -12, 0, 18)
	errorLogHint.Position = UDim2.new(0, 6, 0, 42)
	errorLogHint.BackgroundTransparency = 1
	errorLogHint.Text = "Live internal errors reported by the script. Newest entries stay at the top."
	errorLogHint.TextColor3 = Color3.fromRGB(110, 116, 132)
	errorLogHint.TextSize = 11
	errorLogHint.Font = Enum.Font.GothamMedium
	errorLogHint.TextXAlignment = Enum.TextXAlignment.Left
	errorLogHint.Parent = errorLogPanel

	local errorLogScroll = Instance.new("ScrollingFrame")
	errorLogScroll.Size = UDim2.new(1, -12, 1, -74)
	errorLogScroll.Position = UDim2.new(0, 6, 0, 62)
	errorLogScroll.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
	errorLogScroll.BorderSizePixel = 0
	errorLogScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	errorLogScroll.ScrollBarThickness = 5
	errorLogScroll.AutomaticCanvasSize = Enum.AutomaticSize.None
	errorLogScroll.Parent = errorLogPanel

	local errorLogScrollCorner = Instance.new("UICorner")
	errorLogScrollCorner.CornerRadius = UDim.new(0, 6)
	errorLogScrollCorner.Parent = errorLogScroll

	local errorLogScrollStroke = Instance.new("UIStroke")
	errorLogScrollStroke.Color = Color3.fromRGB(30, 32, 44)
	errorLogScrollStroke.Thickness = 1
	errorLogScrollStroke.Transparency = 0.22
	errorLogScrollStroke.Parent = errorLogScroll

	local errorLogList = Instance.new("UIListLayout")
	errorLogList.Padding = UDim.new(0, 6)
	errorLogList.SortOrder = Enum.SortOrder.LayoutOrder
	errorLogList.Parent = errorLogScroll

	local errorLogPadding = Instance.new("UIPadding")
	errorLogPadding.PaddingTop = UDim.new(0, 6)
	errorLogPadding.PaddingBottom = UDim.new(0, 6)
	errorLogPadding.PaddingLeft = UDim.new(0, 6)
	errorLogPadding.PaddingRight = UDim.new(0, 6)
	errorLogPadding.Parent = errorLogScroll

	local errorLogEmptyState = Instance.new("TextLabel")
	errorLogEmptyState.Size = UDim2.new(1, -12, 0, 28)
	errorLogEmptyState.BackgroundTransparency = 1
	errorLogEmptyState.Text = "No internal errors logged."
	errorLogEmptyState.TextColor3 = Color3.fromRGB(100, 105, 120)
	errorLogEmptyState.TextSize = 12
	errorLogEmptyState.Font = Enum.Font.GothamMedium
	errorLogEmptyState.LayoutOrder = 1
	errorLogEmptyState.Parent = errorLogScroll

	local function formatAdditionalData(additionalData)
		if additionalData == nil then
			return nil
		end

		local dataType = typeof(additionalData)
		if dataType == "table" then
			local segments = {}
			for key, value in pairs(additionalData) do
				table.insert(segments, tostring(key) .. "=" .. tostring(value))
			end
			table.sort(segments)
			return table.concat(segments, " | ")
		end

		return tostring(additionalData)
	end

	local function createErrorLogEntry(entry, layoutOrder)
		local details = {}
		table.insert(details, string.format("[%s] %s", entry.timestamp or "??:??:??", entry.category or "UNKNOWN"))
		table.insert(details, tostring(entry.message or "Unknown error"))

		local formattedData = formatAdditionalData(entry.additionalData)
		if formattedData and formattedData ~= "" then
			table.insert(details, "Data: " .. formattedData)
		end
		if entry.stackTrace and entry.stackTrace ~= "" then
			table.insert(details, "Stack: " .. tostring(entry.stackTrace))
		end

		local bodyText = table.concat(details, "\n")

		local row = Instance.new("Frame")
		row.Name = "ErrorEntry"
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.Size = UDim2.new(1, 0, 0, 0)
		row.BackgroundColor3 = Color3.fromRGB(18, 20, 29)
		row.BorderSizePixel = 0
		row.LayoutOrder = layoutOrder

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 6)
		rowCorner.Parent = row

		local rowStroke = Instance.new("UIStroke")
		rowStroke.Color = Color3.fromRGB(62, 44, 56)
		rowStroke.Thickness = 1
		rowStroke.Transparency = 0.2
		rowStroke.Parent = row

		local rowPadding = Instance.new("UIPadding")
		rowPadding.PaddingTop = UDim.new(0, 6)
		rowPadding.PaddingBottom = UDim.new(0, 6)
		rowPadding.PaddingLeft = UDim.new(0, 8)
		rowPadding.PaddingRight = UDim.new(0, 8)
		rowPadding.Parent = row

		local rowLabel = Instance.new("TextLabel")
		rowLabel.AutomaticSize = Enum.AutomaticSize.Y
		rowLabel.Size = UDim2.new(1, 0, 0, 0)
		rowLabel.BackgroundTransparency = 1
		rowLabel.Text = bodyText
		rowLabel.TextWrapped = true
		rowLabel.RichText = false
		rowLabel.TextColor3 = Color3.fromRGB(226, 228, 235)
		rowLabel.TextSize = 12
		rowLabel.Font = Enum.Font.Code
		rowLabel.TextXAlignment = Enum.TextXAlignment.Left
		rowLabel.TextYAlignment = Enum.TextYAlignment.Top
		rowLabel.Parent = row

		return row
	end

	local function refreshErrorLogViewer()
		for _, child in ipairs(errorLogScroll:GetChildren()) do
			if child:IsA("Frame") and child.Name == "ErrorEntry" then
				child:Destroy()
			end
		end

		errorLogCount.Text = string.format("%d error%s", #errorLog, #errorLog == 1 and "" or "s")
		errorLogEmptyState.Visible = (#errorLog == 0)

		for index, entry in ipairs(errorLog) do
			local entryFrame = createErrorLogEntry(entry, index + 1)
			entryFrame.Parent = errorLogScroll
		end

		task.defer(function()
			local canvasHeight = errorLogList.AbsoluteContentSize.Y + 12
			errorLogScroll.CanvasSize = UDim2.new(0, 0, 0, canvasHeight)
			errorLogScroll.CanvasPosition = Vector2.new(0, 0)
		end)
	end

	local errorLogViewerOpen = false

	viewErrorLogButton.MouseButton1Click:Connect(function()
		errorLogViewerOpen = not errorLogViewerOpen
		errorLogPanel.Visible = errorLogViewerOpen
		viewErrorLogButton.Text = errorLogViewerOpen and "  Hide Error Log" or "  View Error Log"
		refreshErrorLogViewer()
		logCommand("LOG_VIEW", true, errorLogViewerOpen and "Error log opened" or "Error log closed", 0)
	end)

	copyErrorLogButton.MouseButton1Click:Connect(function()
		local success = false
		local report = getDetailedScriptOutput()

		if setclipboard then
			success = pcall(setclipboard, report)
		elseif toclipboard then
			success = pcall(toclipboard, report)
		elseif Clipboard and Clipboard.set then
			success = pcall(Clipboard.set, report)
		end

		if success then
			copyErrorLogButton.Text = "Copied Output"
			logCommand("LOG_COPY", true, "Detailed script output copied", 0)
		else
			copyErrorLogButton.Text = "Copy Unavailable"
			logError("LOG_COPY", "Clipboard copy is unavailable in this environment", nil, nil)
		end

		task.delay(1.4, function()
			if copyErrorLogButton and copyErrorLogButton.Parent then
				copyErrorLogButton.Text = "Copy Output"
			end
		end)
	end)

	task.spawn(function()
		while screenGui.Parent do
			if errorLogViewerOpen and errorLogPanel.Visible then
				refreshErrorLogViewer()
			end
			task.wait(0.35)
		end
	end)
	end

	function polishRow(row, interactive)
		if not row then return end
		row.BackgroundColor3 = Color3.fromRGB(21, 22, 31)
		if row:IsA("TextButton") or row:IsA("TextLabel") then
			row.TextColor3 = Color3.fromRGB(214, 218, 230)
		end
		if row:IsA("TextButton") then
			row.AutoButtonColor = false
		end

		if not row:FindFirstChild("RowCorner") then
			local corner = Instance.new("UICorner")
			corner.Name = "RowCorner"
			corner.CornerRadius = UDim.new(0, 10)
			corner.Parent = row
		end

		local stroke = row:FindFirstChild("RowStroke")
		if not stroke then
			stroke = Instance.new("UIStroke")
			stroke.Name = "RowStroke"
			stroke.Thickness = 1.1
			stroke.Parent = row
		end
		stroke.Color = Color3.fromRGB(50, 52, 67)
		stroke.Transparency = 0.3

		if interactive and row:IsA("TextButton") then
			row.MouseEnter:Connect(function()
				tweenUI(row, 0.14, {BackgroundColor3 = Color3.fromRGB(28, 30, 41)})
				if stroke and stroke.Parent then
					tweenUI(stroke, 0.14, {Transparency = 0.08})
				end
			end)
			row.MouseLeave:Connect(function()
				tweenUI(row, 0.16, {BackgroundColor3 = Color3.fromRGB(21, 22, 31)})
				if stroke and stroke.Parent then
					tweenUI(stroke, 0.16, {Transparency = 0.3})
				end
			end)
		end
	end

	for _, row in ipairs({
		espToggle, chamsToggle,
		aimToggle, fireRateToggle, alwaysAutoToggle, flashToggle, longMeleeToggle, noRecoilToggle, flyToggle, killAllToggle,
		brightNightToggle, brightNightStrengthRow, customSkyToggle, skyUI.imageRow,
		fovSizeLabel, fireRateIntervalLabel,
	}) do
		polishRow(row, row:IsA("TextButton"))
	end

	for _, inputBox in ipairs({
		fovSizeInput, fireRateIntervalInput,
	}) do
		local inputStroke = inputBox:FindFirstChildOfClass("UIStroke")
		if inputStroke then
			inputStroke.Color = Color3.fromRGB(55, 55, 70)
			inputStroke.Transparency = 0.25
			inputBox.Focused:Connect(function()
				tweenUI(inputBox, 0.1, {BackgroundColor3 = Color3.fromRGB(24, 24, 32)})
				tweenUI(inputStroke, 0.1, {Transparency = 0.02})
			end)
			inputBox.FocusLost:Connect(function()
				tweenUI(inputBox, 0.12, {BackgroundColor3 = Color3.fromRGB(16, 16, 22)})
				tweenUI(inputStroke, 0.12, {Transparency = 0.25})
			end)
		end
	end

	activeTabButton = nil
	local function tweenTabIndicator(positionTarget, sizeTarget)
		if tabIndicatorTween then
			tabIndicatorTween:Cancel()
		end
		tabIndicatorTween = TweenService:Create(
			tabIndicator,
			TweenInfo.new(0.28, Enum.EasingStyle.Circular, Enum.EasingDirection.Out),
			{
				Position = positionTarget,
				Size = sizeTarget,
			}
		)
		tabIndicatorTween.Completed:Connect(function()
			if tabIndicatorTween and tabIndicatorTween.PlaybackState ~= Enum.PlaybackState.Playing then
				tabIndicatorTween = nil
			end
		end)
		tabIndicatorTween:Play()
	end

	function setActiveTabStyle(tab)
		activeTabButton = tab
		for _, eachTab in ipairs({visualTab, combatTab, worldTab, settingsTab}) do
			local isActive = (eachTab == tab)
			local isHovered = tabHoverState[eachTab] == true
			local bgColor = isActive and Color3.fromRGB(30, 32, 46) or (isHovered and Color3.fromRGB(22, 24, 34) or Color3.fromRGB(18, 18, 26))
			local textColor = isActive and Color3.fromRGB(248, 249, 255) or (isHovered and Color3.fromRGB(205, 210, 225) or Color3.fromRGB(146, 151, 168))
			local textTransparency = isActive and 0 or (isHovered and 0.01 or 0.05)
			tweenUI(eachTab, 0.2, {
				BackgroundColor3 = bgColor,
				TextColor3 = textColor,
				TextTransparency = textTransparency,
			})
			local tabStroke = eachTab:FindFirstChildOfClass("UIStroke")
			if tabStroke then
				tweenUI(tabStroke, 0.2, {
					Transparency = isActive and 0.12 or (isHovered and 0.32 or 0.56),
					Thickness = isActive and 1.3 or 1,
				})
			end

			local tabScale = tabScales[eachTab]
			if tabScale then
				tweenUI(tabScale, 0.2, {
					Scale = isActive and 1.015 or (isHovered and 1.006 or 1),
				})
			end
		end

		local pos = tab.Position
		tweenTabIndicator(
			UDim2.new(
				pos.X.Scale,
				pos.X.Offset + TAB_INDICATOR_INSET + 2,
				1,
				-(TAB_INDICATOR_HEIGHT + TAB_INDICATOR_BOTTOM_PADDING)
			),
			UDim2.new(
				tab.Size.X.Scale,
				tab.Size.X.Offset - (TAB_INDICATOR_INSET * 2),
				0,
				TAB_INDICATOR_HEIGHT
			)
		)
	end

	local currentContentTab = "visual"

	local function showMenuTab(tabName)
		currentContentTab = tabName
		visualContent.Visible = tabName == "visual"
		combatContent.Visible = tabName == "combat"
		worldContent.Visible = tabName == "world"
		settingsContent.Visible = tabName == "settings"

		if tabName == "visual" then
			setActiveTabStyle(visualTab)
		elseif tabName == "combat" then
			setActiveTabStyle(combatTab)
		elseif tabName == "world" then
			setActiveTabStyle(worldTab)
		elseif tabName == "settings" then
			setActiveTabStyle(settingsTab)
		end
	end

	for _, eachTab in ipairs({visualTab, combatTab, worldTab, settingsTab}) do
		eachTab.AutoButtonColor = false
		eachTab.MouseEnter:Connect(function()
			tabHoverState[eachTab] = true
			if activeTabButton then
				setActiveTabStyle(activeTabButton)
			end
		end)
		eachTab.MouseLeave:Connect(function()
			tabHoverState[eachTab] = false
			if activeTabButton then
				setActiveTabStyle(activeTabButton)
			end
		end)
	end

	showMenuTab("visual")

	-- =============== WINDOW DRAG HANDLING ===============
	local dragging, dragStart, startPos

	topBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragStart = input.Position
			startPos = mainFrame.Position
		end
	end)

	topBar.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local delta = input.Position - dragStart
			mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)

	-- =============== RGB AND GLITCH VISUAL LOOP ===============
	local visualState = {
		hue = 0,
		pulse = 0,
		currentRgbColor = Color3.fromRGB(255, 40, 80),
		menuAccentColor = Color3.fromRGB(0, 0, 0),
		connection = nil
	}
	local espState = {
		enabled = false,
		connections = {},
		guis = {},
		glows = {},
		boxes = {},
		skeletons = {},
		charConnections = {}
	}

	local chamsState = {
		enabled = false,
		glowName = "GangstaChamsGlow",
		boxes = {},
		connections = {},
	}

	local chamsBoxes = chamsState.boxes
	local chamsHighlights = {}

	-- Backward-compatible aliases used by older call sites.
	local function createCornerESP() end
	local function removeCharacterESP(character)
		if espState.guis[character] then
			if type(espState.guis[character]) == "table" and espState.guis[character].gui then
				pcall(function() espState.guis[character].gui:Destroy() end)
			else
				pcall(function() espState.guis[character]:Destroy() end)
			end
			espState.guis[character] = nil
		end
		if espState.glows[character] then
			pcall(function() espState.glows[character]:Destroy() end)
			espState.glows[character] = nil
		end
		if espState.boxes[character] then
			for part, orig in pairs(espState.boxes[character]) do
				if part and part.Parent then
					part.Color = orig.Color
					part.Material = orig.Material
					part.Transparency = orig.Transparency
					part.CastShadow = orig.CastShadow
				end
			end
			espState.boxes[character] = nil
		end
		if espState.charConnections[character] then
			for _, conn in ipairs(espState.charConnections[character]) do
				pcall(function() conn:Disconnect() end)
			end
			espState.charConnections[character] = nil
		end
	end
	local function refreshPlayerESP() end
	local function refreshAllESP() end
	worldFx = {
		brightNight = false,
		brightNightStrength = worldBrightNightStrength,
		customSky = false,
		skyColor = Color3.fromRGB(135, 170, 220),
		skyHSV = {0.58, 0.39, 0.86}, -- H, S, V
		skyInstance = nil,
		defaultSky = nil,
		defaults = nil,
		atmosphere = nil,
		colorCorrection = nil,
		isApplying = false,
	}

	local function captureWorldDefaults()
		if worldFx.defaults then return end
		worldFx.defaults = {
			Brightness = Lighting.Brightness,
			ClockTime = Lighting.ClockTime,
			Ambient = Lighting.Ambient,
			OutdoorAmbient = Lighting.OutdoorAmbient,
			FogEnd = Lighting.FogEnd,
			FogColor = Lighting.FogColor,
			ColorShift_Top = Lighting.ColorShift_Top,
			ColorShift_Bottom = Lighting.ColorShift_Bottom,
			EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
			EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
			ExposureCompensation = Lighting.ExposureCompensation,
			GlobalShadows = Lighting.GlobalShadows,
			ShadowSoftness = Lighting.ShadowSoftness,
		}
		local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
		if atmosphere then
			worldFx.defaults.Atmosphere = {
				Density = atmosphere.Density,
				Offset = atmosphere.Offset,
				Color = atmosphere.Color,
				Decay = atmosphere.Decay,
				Glare = atmosphere.Glare,
				Haze = atmosphere.Haze,
			}
		end

		local existingSky = Lighting:FindFirstChildOfClass("Sky")
		if existingSky then
			local previousArchivable = existingSky.Archivable
			existingSky.Archivable = true
			local ok, clonedSky = pcall(function()
				return existingSky:Clone()
			end)
			existingSky.Archivable = previousArchivable
			if ok then
				worldFx.defaultSky = clonedSky
			end
		end
	end

	local function ensureWorldFxInstances()
		if not worldFx.atmosphere or not worldFx.atmosphere.Parent then
			worldFx.atmosphere = Instance.new("Atmosphere")
			worldFx.atmosphere.Name = "GangstaWorldAtmosphere"
			worldFx.atmosphere.Parent = Lighting
		end
		if not worldFx.colorCorrection or not worldFx.colorCorrection.Parent then
			worldFx.colorCorrection = Instance.new("ColorCorrectionEffect")
			worldFx.colorCorrection.Name = "GangstaWorldColorCorrection"
			worldFx.colorCorrection.Parent = Lighting
		end
		return worldFx.atmosphere, worldFx.colorCorrection
	end

	local function removeWorldFxInstances()
		if worldFx.atmosphere then
			worldFx.atmosphere:Destroy()
			worldFx.atmosphere = nil
		end
		if worldFx.colorCorrection then
			worldFx.colorCorrection:Destroy()
			worldFx.colorCorrection = nil
		end
	end

	updateWorldFxStatus = function()
		local strengthText = string.format(" x%.2f", worldFx.brightNightStrength or 1)
		if worldFx.brightNight and worldFx.customSky then
			worldModeStatus.Text = "World FX: Bright Night" .. strengthText .. " + Custom Sky"
		elseif worldFx.brightNight then
			worldModeStatus.Text = "World FX: Bright Night" .. strengthText
		elseif worldFx.customSky then
			worldModeStatus.Text = "World FX: Custom Sky"
		else
			worldModeStatus.Text = "World FX: Default Lighting"
		end
	end

	local function restoreDefaultSky()
		for _, child in ipairs(Lighting:GetChildren()) do
			if child:IsA("Sky") and child.Name == "GangstaCustomSky" then
				child:Destroy()
			end
		end

		if worldFx.defaultSky and not Lighting:FindFirstChild(worldFx.defaultSky.Name) then
			local clonedSky = worldFx.defaultSky:Clone()
			clonedSky.Parent = Lighting
		end
	end

	local function restoreWorldLighting()
		captureWorldDefaults()
		if not worldFx.defaults then
			return
		end

		local defaults = worldFx.defaults
		Lighting.Brightness = defaults.Brightness
		Lighting.ClockTime = defaults.ClockTime
		Lighting.Ambient = defaults.Ambient
		Lighting.OutdoorAmbient = defaults.OutdoorAmbient
		Lighting.FogEnd = defaults.FogEnd
		Lighting.FogColor = defaults.FogColor
		Lighting.ColorShift_Top = defaults.ColorShift_Top
		Lighting.ColorShift_Bottom = defaults.ColorShift_Bottom
		Lighting.EnvironmentDiffuseScale = defaults.EnvironmentDiffuseScale
		Lighting.EnvironmentSpecularScale = defaults.EnvironmentSpecularScale
		Lighting.ExposureCompensation = defaults.ExposureCompensation
		Lighting.GlobalShadows = defaults.GlobalShadows
		Lighting.ShadowSoftness = defaults.ShadowSoftness

		if worldFx.atmosphere and worldFx.atmosphere.Parent then
			if defaults.Atmosphere then
				worldFx.atmosphere.Density = defaults.Atmosphere.Density
				worldFx.atmosphere.Offset = defaults.Atmosphere.Offset
				worldFx.atmosphere.Color = defaults.Atmosphere.Color
				worldFx.atmosphere.Decay = defaults.Atmosphere.Decay
				worldFx.atmosphere.Glare = defaults.Atmosphere.Glare
				worldFx.atmosphere.Haze = defaults.Atmosphere.Haze
			else
				worldFx.atmosphere:Destroy()
				worldFx.atmosphere = nil
			end
		end

		if worldFx.colorCorrection and worldFx.colorCorrection.Parent then
			worldFx.colorCorrection:Destroy()
			worldFx.colorCorrection = nil
		end

		restoreDefaultSky()
		updateWorldFxStatus()
	end

	local function ensureCustomSkyInstance()
		if worldFx.skyInstance and worldFx.skyInstance.Parent then
			return worldFx.skyInstance
		end

		local sky = Instance.new("Sky")
		sky.Name = "GangstaCustomSky"
		sky.CelestialBodiesShown = false
		sky.StarCount = 0
		sky.MoonAngularSize = 0
		sky.SunAngularSize = 0
		sky.Parent = Lighting
		worldFx.skyInstance = sky
		return sky
	end

	local function applySkyPresetToInstance(sky, preset)
		if not sky then
			return
		end

		local primary = preset and (
			preset.bk
			or preset.dn
			or preset.ft
			or preset.lf
			or preset.rt
			or preset.up
		)
		if primary and primary ~= "" then
			sky.SkyboxBk = preset.bk or primary
			sky.SkyboxDn = preset.dn or primary
			sky.SkyboxFt = preset.ft or primary
			sky.SkyboxLf = preset.lf or primary
			sky.SkyboxRt = preset.rt or primary
			sky.SkyboxUp = preset.up or primary
		else
			sky.SkyboxBk = ""
			sky.SkyboxDn = ""
			sky.SkyboxFt = ""
			sky.SkyboxLf = ""
			sky.SkyboxRt = ""
			sky.SkyboxUp = ""
		end
	end

	applyWorldFx = function()
		if worldFx.isApplying then return end
		worldFx.isApplying = true
		captureWorldDefaults()
		if not worldFx.defaults then
			worldFx.isApplying = false
			return
		end

		if not worldFx.brightNight then
			if worldFx.customSky then
				updateWorldFxStatus()
				worldFx.isApplying = false
				return
			end

			restoreWorldLighting()
			worldFx.isApplying = false
			return
		end

		local atmosphere, colorCorrection = ensureWorldFxInstances()
		local strength = math.clamp(worldFx.brightNightStrength or 1, 0.6, 2.4)
		-- Smooth fullbright: all materials/ground/trees/sky visible, no white glare, easy on eyes
		Lighting.ClockTime = 12
		Lighting.Brightness = math.clamp(1.5 + (0.55 * strength), 1.2, 3.2)
		Lighting.Ambient = Color3.fromRGB(170, 170, 175):Lerp(Color3.fromRGB(225, 225, 232), (strength - 0.6) / 1.8)
		Lighting.OutdoorAmbient = Color3.fromRGB(170, 170, 175):Lerp(Color3.fromRGB(225, 225, 232), (strength - 0.6) / 1.8)
		Lighting.GlobalShadows = false
		Lighting.ShadowSoftness = 1
		Lighting.EnvironmentDiffuseScale = 1
		Lighting.EnvironmentSpecularScale = 0
		Lighting.ExposureCompensation = 0
		Lighting.ColorShift_Top = Color3.fromRGB(160, 165, 175)
		Lighting.ColorShift_Bottom = Color3.fromRGB(150, 155, 165)
		Lighting.FogColor = Color3.fromRGB(140, 145, 155)
		Lighting.FogEnd = 1000000
		atmosphere.Density = 0
		atmosphere.Offset = 0
		atmosphere.Color = Color3.fromRGB(170, 175, 185)
		atmosphere.Decay = Color3.fromRGB(160, 165, 175)
		atmosphere.Glare = 0
		atmosphere.Haze = 0
		colorCorrection.TintColor = Color3.fromRGB(235, 235, 240)
		colorCorrection.Brightness = 0.03 + (0.045 * (strength - 0.6) / 1.8)
		colorCorrection.Contrast = 0.04 + (0.05 * (strength - 0.6) / 1.8)
		colorCorrection.Saturation = -0.05
		updateWorldFxStatus()
		worldFx.isApplying = false
	end

	updateWorldFxStatus()

	-- =============== CUSTOM SKY SYSTEM ===============
	local function colorToHex(c3)
		local r = math.clamp(math.floor(c3.R * 255 + 0.5), 0, 255)
		local g = math.clamp(math.floor(c3.G * 255 + 0.5), 0, 255)
		local b = math.clamp(math.floor(c3.B * 255 + 0.5), 0, 255)
		return string.format("%02X%02X%02X", r, g, b)
	end

	local function hexToColor(hex)
		hex = hex:gsub("#", ""):gsub(" ", "")
		if #hex ~= 6 then return nil end
		local r = tonumber(hex:sub(1, 2), 16)
		local g = tonumber(hex:sub(3, 4), 16)
		local b = tonumber(hex:sub(5, 6), 16)
		if not r or not g or not b then return nil end
		return Color3.fromRGB(r, g, b)
	end

	local function syncUIFromColor(color)
		local r = math.clamp(math.floor(color.R * 255 + 0.5), 0, 255)
		local g = math.clamp(math.floor(color.G * 255 + 0.5), 0, 255)
		local b = math.clamp(math.floor(color.B * 255 + 0.5), 0, 255)
		skyInputs.r.Text = tostring(r)
		skyInputs.g.Text = tostring(g)
		skyInputs.b.Text = tostring(b)
		skyInputs.hex.Text = colorToHex(color)
		skyUI.preview.BackgroundColor3 = color

		local h, s, v = Color3.toHSV(color)
		worldFx.skyHSV = {h, s, v}
		worldFx.skyColor = color

		-- Update canvas base hue and cursor positions
		skyUI.hsCanvas.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		skyUI.svCursor.Position = UDim2.new(s, -5, 1 - v, -5)
		skyUI.hueCursor.Position = UDim2.new(0, -2, h, -2)
	end

	local function parseSkyColorInputs()
		local r = math.clamp(tonumber(skyInputs.r.Text) or 135, 0, 255)
		local g = math.clamp(tonumber(skyInputs.g.Text) or 170, 0, 255)
		local b = math.clamp(tonumber(skyInputs.b.Text) or 220, 0, 255)
		return Color3.fromRGB(r, g, b), r, g, b
	end

	applyCustomSky = function()
		if worldFx.isApplying then return end
		worldFx.isApplying = true
		captureWorldDefaults()

		if not worldFx.customSky then
			-- Destroy our sky instance
			if worldFx.skyInstance and worldFx.skyInstance.Parent then
				worldFx.skyInstance:Destroy()
				worldFx.skyInstance = nil
			end
			-- Restore Lighting properties we modified
			if worldFx.brightNight then
				worldFx.isApplying = false
				applyWorldFx()
				skyStatus.Text = "Sky: Default"
				return
			else
				restoreWorldLighting()
			end
			skyStatus.Text = "Sky: Default"
			updateWorldFxStatus()
			worldFx.isApplying = false
			return
		end

		local preset = skyUI.presets[skyUI.imageIndex]
		local skyColor = worldFx.skyColor

		for _, child in ipairs(Lighting:GetChildren()) do
			if child:IsA("Sky") and child.Name ~= "GangstaCustomSky" then
				child:Destroy()
			end
		end

		local sky = ensureCustomSkyInstance()
		if preset and preset.name == "Game Default" and worldFx.defaultSky then
			applySkyPresetToInstance(sky, {
				bk = worldFx.defaultSky.SkyboxBk,
				dn = worldFx.defaultSky.SkyboxDn,
				ft = worldFx.defaultSky.SkyboxFt,
				lf = worldFx.defaultSky.SkyboxLf,
				rt = worldFx.defaultSky.SkyboxRt,
				up = worldFx.defaultSky.SkyboxUp,
			})
			sky.CelestialBodiesShown = worldFx.defaultSky.CelestialBodiesShown
			sky.StarCount = worldFx.defaultSky.StarCount
			sky.MoonAngularSize = worldFx.defaultSky.MoonAngularSize
			sky.SunAngularSize = worldFx.defaultSky.SunAngularSize
			if worldFx.defaultSky.SunTextureId ~= nil then
				sky.SunTextureId = worldFx.defaultSky.SunTextureId
			end
			if worldFx.defaultSky.MoonTextureId ~= nil then
				sky.MoonTextureId = worldFx.defaultSky.MoonTextureId
			end
		else
			sky.CelestialBodiesShown = false
			sky.StarCount = 0
			sky.MoonAngularSize = 0
			sky.SunAngularSize = 0
			applySkyPresetToInstance(sky, preset)
		end

		-- Apply color tint to the scene
		Lighting.ClockTime = 14
		Lighting.Brightness = 1
		Lighting.ColorShift_Top = skyColor
		Lighting.ColorShift_Bottom = skyColor:Lerp(Color3.fromRGB(0, 0, 0), 0.35)
		Lighting.FogColor = skyColor:Lerp(Color3.fromRGB(30, 30, 40), 0.3)
		Lighting.FogEnd = 100000
		Lighting.Ambient = skyColor:Lerp(Color3.fromRGB(60, 60, 70), 0.5)
		Lighting.OutdoorAmbient = skyColor:Lerp(Color3.fromRGB(80, 80, 90), 0.4)
		Lighting.GlobalShadows = false
		Lighting.EnvironmentDiffuseScale = 0
		Lighting.EnvironmentSpecularScale = 0

		if worldFx.brightNight then
			local strength = math.clamp(worldFx.brightNightStrength or 1, 0.6, 2.4)
			local brightBlend = (strength - 0.6) / 1.8
			Lighting.Brightness = math.max(Lighting.Brightness, 1.2 + (0.9 * brightBlend))
			Lighting.Ambient = Lighting.Ambient:Lerp(Color3.fromRGB(220, 220, 228), 0.28 + (0.22 * brightBlend))
			Lighting.OutdoorAmbient = Lighting.OutdoorAmbient:Lerp(Color3.fromRGB(226, 226, 234), 0.28 + (0.22 * brightBlend))
			Lighting.FogEnd = math.max(Lighting.FogEnd, 500000)
		end

		local atm, colorCorrection = ensureWorldFxInstances()
		atm.Color = skyColor
		atm.Decay = skyColor:Lerp(Color3.fromRGB(0, 0, 0), 0.4)
		atm.Density = worldFx.brightNight and 0.12 or 0.35
		atm.Offset = 0.25
		atm.Glare = 0
		atm.Haze = worldFx.brightNight and 0.8 or 2.5
		colorCorrection.TintColor = skyColor:Lerp(Color3.fromRGB(255, 255, 255), 0.7)
		colorCorrection.Brightness = worldFx.brightNight and 0.06 or 0.02
		colorCorrection.Contrast = 0.08
		colorCorrection.Saturation = worldFx.brightNight and 0.01 or 0.05

		local r = math.floor(skyColor.R * 255 + 0.5)
		local g = math.floor(skyColor.G * 255 + 0.5)
		local b = math.floor(skyColor.B * 255 + 0.5)
		local suffix = preset.bk and (" [" .. preset.name .. "]") or ""
		skyStatus.Text = string.format("Sky: %d, %d, %d%s", r, g, b, suffix)
		updateWorldFxStatus()
		worldFx.isApplying = false
	end

	-- Store applyFn reference for sky image prev/next buttons
	skyUI.applyFn = function()
		syncUIFromColor(worldFx.skyColor)
		applyCustomSky()
	end

	-- Protect our sky: if the game adds/replaces Sky objects while Custom Sky is on, remove them
	Lighting.ChildAdded:Connect(function(child)
		if worldFx.customSky and child:IsA("Sky") and child.Name ~= "GangstaCustomSky" then
			child:Destroy()
		end
	end)

	local worldFxRefreshQueued = false
	local function queueWorldFxRefresh()
		if worldFx.isApplying then
			return
		end
		if not (worldFx.brightNight or worldFx.customSky) then
			return
		end
		if worldFxRefreshQueued then
			return
		end

		worldFxRefreshQueued = true
		task.delay(0.05, function()
			worldFxRefreshQueued = false
			if worldFx.isApplying then
				return
			end
			if worldFx.customSky then
				applyCustomSky()
			elseif worldFx.brightNight then
				applyWorldFx()
			end
		end)
	end

	for _, propertyName in ipairs({
		"Brightness",
		"ClockTime",
		"Ambient",
		"OutdoorAmbient",
		"FogColor",
		"FogEnd",
		"GlobalShadows",
		"EnvironmentDiffuseScale",
		"EnvironmentSpecularScale",
		"ExposureCompensation",
		"ColorShift_Top",
		"ColorShift_Bottom",
	}) do
		Lighting:GetPropertyChangedSignal(propertyName):Connect(queueWorldFxRefresh)
	end

	Lighting.ChildRemoved:Connect(function(child)
		if not (worldFx.brightNight or worldFx.customSky) then
			return
		end
		if child == worldFx.skyInstance or child == worldFx.atmosphere or child == worldFx.colorCorrection then
			queueWorldFxRefresh()
		end
	end)

	local function updateSkyAndApply()
		local color = parseSkyColorInputs()
		syncUIFromColor(color)
		if worldFx.customSky then
			applyCustomSky()
		end
	end

	-- RGB input boxes → update on focus lost
	for _, input in ipairs({skyInputs.r, skyInputs.g, skyInputs.b}) do
		input.FocusLost:Connect(function()
			updateSkyAndApply()
		end)
	end

	-- Hex input → update on focus lost
	skyInputs.hex.FocusLost:Connect(function()
		local color = hexToColor(skyInputs.hex.Text)
		if color then
			syncUIFromColor(color)
			if worldFx.customSky then applyCustomSky() end
		else
			skyInputs.hex.Text = colorToHex(worldFx.skyColor)
		end
	end)

	-- Hue/Saturation canvas dragging
	do
		local draggingSV = false
		local draggingHue = false

		local function updateFromSV(inputPos)
			local absPos = skyUI.hsCanvas.AbsolutePosition
			local absSize = skyUI.hsCanvas.AbsoluteSize
			local s = math.clamp((inputPos.X - absPos.X) / absSize.X, 0, 1)
			local v = math.clamp(1 - (inputPos.Y - absPos.Y) / absSize.Y, 0, 1)
			local h = worldFx.skyHSV[1]
			local color = Color3.fromHSV(h, s, v)
			syncUIFromColor(color)
			if worldFx.customSky then applyCustomSky() end
		end

		local function updateFromHue(inputPos)
			local absPos = skyUI.hueBar.AbsolutePosition
			local absSize = skyUI.hueBar.AbsoluteSize
			local h = math.clamp((inputPos.Y - absPos.Y) / absSize.Y, 0, 0.999)
			local s = worldFx.skyHSV[2]
			local v = worldFx.skyHSV[3]
			local color = Color3.fromHSV(h, s, v)
			syncUIFromColor(color)
			if worldFx.customSky then applyCustomSky() end
		end

		skyUI.hsCanvas.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or
			   input.UserInputType == Enum.UserInputType.Touch then
				draggingSV = true
				updateFromSV(input.Position)
			end
		end)

		skyUI.hueBar.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or
			   input.UserInputType == Enum.UserInputType.Touch then
				draggingHue = true
				updateFromHue(input.Position)
			end
		end)

		UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or
			   input.UserInputType == Enum.UserInputType.Touch then
				if draggingSV then updateFromSV(input.Position) end
				if draggingHue then updateFromHue(input.Position) end
			end
		end)

		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or
			   input.UserInputType == Enum.UserInputType.Touch then
				draggingSV = false
				draggingHue = false
			end
		end)
	end

	-- Initialize picker cursor positions from default color
	syncUIFromColor(worldFx.skyColor)

	customSkyToggle.MouseButton1Click:Connect(function()
		worldFx.customSky = not worldFx.customSky
		setCustomSkyCheck(worldFx.customSky)
		if worldFx.customSky then
			syncUIFromColor(worldFx.skyColor)
			applyCustomSky()
		else
			applyCustomSky()
		end
	end)

	-- Rain particles are intentionally lightweight to keep UI responsive.
	local rainRenderConnection
	do
	local rainParticles = {}
	local rainMaxParticles = 120
	local rainTime = 0

	local function createRainParticle()
		local drop = Instance.new("Frame")
		local width = (math.random() < 0.26) and 2 or 1
		local length = math.random(14, 30)
		drop.Size = UDim2.new(0, width, 0, length)
		drop.Position = UDim2.new(0, math.random(0, mainFrame.AbsoluteSize.X > 0 and mainFrame.AbsoluteSize.X or 400), 0, math.random(-420, -10))
		drop.BackgroundColor3 = Color3.fromRGB(172, 186, 255)
		drop.BackgroundTransparency = 0.25 + (math.random() * 0.32)
		drop.BorderSizePixel = 0
		drop.ZIndex = 9998
		drop.Parent = rainLayer

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = drop

		local streak = Instance.new("UIGradient")
		streak.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 140, 220)),
			ColorSequenceKeypoint.new(0.35, Color3.fromRGB(175, 195, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(98, 118, 198)),
		})
		streak.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.25, 0.58),
			NumberSequenceKeypoint.new(0.72, 0.16),
			NumberSequenceKeypoint.new(1, 0.72),
		})
		streak.Rotation = 90
		streak.Parent = drop

		rainParticles[#rainParticles + 1] = {
			Instance = drop,
			X = drop.Position.X.Offset,
			Y = drop.Position.Y.Offset,
			Speed = math.random(240, 430),
			Drift = math.random(-20, 20),
			SwayAmp = math.random(2, 8),
			SwayFreq = 1.2 + (math.random() * 1.6),
			SwayPhase = math.random() * math.pi * 2,
			Twinkle = 1.6 + (math.random() * 2.4),
			BaseAlpha = drop.BackgroundTransparency,
		}
	end

	for _ = 1, rainMaxParticles do
		createRainParticle()
	end

	rainRenderConnection = RunService.RenderStepped:Connect(function(dt)
		if not mainFrame or not mainFrame.Parent then
			return
		end
		if not mainFrame.Visible then
			return
		end

		local frameDt = math.min(dt, 1 / 25)
		rainTime = rainTime + frameDt

		local width = math.max(mainFrame.AbsoluteSize.X, 1)
		local height = math.max(mainFrame.AbsoluteSize.Y, 1)

		for _, particle in ipairs(rainParticles) do
			local drop = particle.Instance
			if drop and drop.Parent then
				particle.Y = particle.Y + (particle.Speed * frameDt)
				particle.X = particle.X + (particle.Drift * frameDt)

				local x = particle.X + (math.sin((rainTime * particle.SwayFreq) + particle.SwayPhase) * particle.SwayAmp)
				local y = particle.Y

				if y > height + 24 then
					y = math.random(-420, -12)
					x = math.random(-12, width + 12)
					particle.X = x
					particle.Y = y
					particle.Speed = math.random(240, 430)
					particle.Drift = math.random(-20, 20)
					particle.SwayAmp = math.random(2, 8)
					particle.SwayFreq = 1.2 + (math.random() * 1.6)
					particle.SwayPhase = math.random() * math.pi * 2
					particle.Twinkle = 1.6 + (math.random() * 2.4)
				elseif x > (width + 20) then
					x = -20
					particle.X = x
				elseif x < -20 then
					x = width + 20
					particle.X = x
				end

				drop.BackgroundTransparency = math.clamp(
					particle.BaseAlpha + (math.sin((rainTime * particle.Twinkle) + particle.SwayPhase) * 0.08),
					0.14,
					0.9
				)

				drop.Position = UDim2.new(0, x, 0, y)
			end
		end
	end)
	end -- do (rain particles)

	-- =============== TEAM FILTERING ===============
	local function safeGetPlayerProperty(plr, propertyName)
		if not plr then return nil end
		local ok, value = pcall(function()
			return plr[propertyName]
		end)
		if ok then
			return value
		end
		return nil
	end

	local function getPlayerTeam(plr)
		return safeGetPlayerProperty(plr, "Team")
	end

	local function getPlayerTeamColor(plr)
		return safeGetPlayerProperty(plr, "TeamColor")
	end

	local function isPlayerNeutral(plr)
		return safeGetPlayerProperty(plr, "Neutral") == true
	end

	local function getCharacterRoot(character)
		if not character or not character.Parent then return nil end
		return character:FindFirstChild("HumanoidRootPart")
	end

	local function hasCharacterRoot(plr)
		return getCharacterRoot(plr and plr.Character) ~= nil
	end

	local teamCheckState = {
		arsenalFfa = false,
		lastScan = 0,
	}

	local ARSENAL_FFA_MODE_HINTS = {
		"ffa",
		"free for all",
		"standard",
		"competitive",
		"legacy",
		"randomizer",
		"gun rotation",
		"concussion mania",
		"railgun royale",
		"laser tag",
		"knife fight",
		"swordfights",
		"wild west",
		"brickbattle",
		"firework launcher",
		"projectile party",
		"headshots only",
		"snipers only",
		"all weapons",
		"arcade free for all",
		"randomizer ffa",
	}

	local ARSENAL_TEAM_MODE_HINTS = {
		"tdm",
		"team deathmatch",
		"kill confirmed",
		"capture the flag",
		"operation: infiltration",
		"operation infiltration",
		"oddball",
		"slaughter",
		"clown infection",
		"juggernaut",
		"hackula",
		"counter blox",
		"typical colors 2",
		"infiltration",
	}

	local function modeTextIndicatesFFA(text)
		if type(text) ~= "string" then return false end
		local lowered = string.lower(text)
		for _, hint in ipairs(ARSENAL_FFA_MODE_HINTS) do
			if string.find(lowered, hint, 1, true) ~= nil then
				return true
			end
		end
		return false
	end

	local function modeTextIndicatesTeam(text)
		if type(text) ~= "string" then return false end
		local lowered = string.lower(text)
		for _, hint in ipairs(ARSENAL_TEAM_MODE_HINTS) do
			if string.find(lowered, hint, 1, true) ~= nil then
				return true
			end
		end
		return false
	end

	local function classifyArsenalModeText(text)
		if type(text) ~= "string" then return nil end
		if modeTextIndicatesFFA(text) then
			return "ffa"
		end
		if modeTextIndicatesTeam(text) then
			return "team"
		end
		return nil
	end

	local function evaluateModeObject(candidate)
		if not candidate then return nil end
		if candidate:IsA("StringValue") then
			return classifyArsenalModeText(candidate.Value)
		end
		return classifyArsenalModeText(candidate.Name)
	end

	local function isArsenalFFA()
		if game.PlaceId ~= 286090429 then
			return false
		end

		local now = tick()
		if (now - teamCheckState.lastScan) < 0.9 then
			return teamCheckState.arsenalFfa
		end
		teamCheckState.lastScan = now

		local modeCandidates = {
			ReplicatedStorage:FindFirstChild("GameMode"),
			ReplicatedStorage:FindFirstChild("Gamemode"),
			ReplicatedStorage:FindFirstChild("CurrentGameMode"),
			ReplicatedStorage:FindFirstChild("CurrentGamemode"),
			ReplicatedStorage:FindFirstChild("Mode"),
			ReplicatedStorage:FindFirstChild("CurrentMode"),
			workspace:FindFirstChild("GameMode"),
			workspace:FindFirstChild("Gamemode"),
			workspace:FindFirstChild("CurrentGameMode"),
			workspace:FindFirstChild("CurrentGamemode"),
			workspace:FindFirstChild("Mode"),
			workspace:FindFirstChild("CurrentMode"),
		}

		for _, candidate in ipairs(modeCandidates) do
			local modeClass = evaluateModeObject(candidate)
			if modeClass == "ffa" then
				teamCheckState.arsenalFfa = true
				return true
			elseif modeClass == "team" then
				teamCheckState.arsenalFfa = false
				return false
			end
		end

		for _, attrName in ipairs({"GameMode", "Gamemode", "CurrentGameMode", "CurrentGamemode", "Mode", "CurrentMode"}) do
			local modeClass = classifyArsenalModeText(ReplicatedStorage:GetAttribute(attrName))
				or classifyArsenalModeText(workspace:GetAttribute(attrName))
			if modeClass == "ffa" then
				teamCheckState.arsenalFfa = true
				return true
			elseif modeClass == "team" then
				teamCheckState.arsenalFfa = false
				return false
			end
		end

		local myTeam = getPlayerTeam(player)
		if myTeam and modeTextIndicatesFFA(myTeam.Name) then
			teamCheckState.arsenalFfa = true
			return true
		end

		local allTeams = Teams:GetTeams()
		if #allTeams <= 1 then
			teamCheckState.arsenalFfa = true
			return true
		end

		teamCheckState.arsenalFfa = false
		return false
	end

	local function shareTeamColor(plrA, plrB)
		if isPlayerNeutral(plrA) or isPlayerNeutral(plrB) then
			return false
		end

		local teamColorA = getPlayerTeamColor(plrA)
		local teamColorB = getPlayerTeamColor(plrB)
		if teamColorA == nil or teamColorB == nil then
			return false
		end

		return teamColorA == teamColorB
	end

	local function isSameTeam(plr)
		if plr == player then return true end
		if not plr or not player then return false end

		-- Arsenal FFA can still populate Team/TeamColor in ways that make every player look friendly.
		if isArsenalFFA() then
			return false
		end

		local myTeam = getPlayerTeam(player)
		local theirTeam = getPlayerTeam(plr)
		if myTeam ~= nil and theirTeam ~= nil then
			return myTeam == theirTeam
		end

		if shareTeamColor(player, plr) then
			return true
		end

		return false
	end

	refreshPlayerESP = function(plr)
		if not plr or plr == player then return end

		local character = plr.Character
		if not espState.enabled then
			if character then
				removeCharacterESP(character)
			end
			return
		end

		if isSameTeam(plr) then
			if character then
				removeCharacterESP(character)
			end
			return
		end

		if hasCharacterRoot(plr) then
			createCornerESP(character)
		end
		
		if character and not hasCharacterRoot(plr) then
			removeCharacterESP(character)
		end
	end

	local function updateESPInfo()
		-- Update skeleton positions
		for character, skeletonLines in pairs(espState.skeletons) do
			if type(skeletonLines) ~= "table" then
				espState.skeletons[character] = nil
				continue
			end
			local char = character
			if char and char.Parent then
				local isR15 = char:FindFirstChild("UpperTorso") ~= nil
				local skeletonConnections
				if isR15 then
					skeletonConnections = {
						{"Head", "UpperTorso"},
						{"UpperTorso", "LowerTorso"},
						{"LowerTorso", "LeftUpperLeg"},
						{"LowerTorso", "RightUpperLeg"},
						{"LeftUpperLeg", "LeftLowerLeg"},
						{"LeftLowerLeg", "LeftFoot"},
						{"RightUpperLeg", "RightLowerLeg"},
						{"RightLowerLeg", "RightFoot"},
						{"UpperTorso", "LeftUpperArm"},
						{"UpperTorso", "RightUpperArm"},
						{"LeftUpperArm", "LeftLowerArm"},
						{"LeftLowerArm", "LeftHand"},
						{"RightUpperArm", "RightLowerArm"},
						{"RightLowerArm", "RightHand"}
					}
				else
					skeletonConnections = {
						{"Head", "Torso"},
						{"Torso", "Left Arm"},
						{"Torso", "Right Arm"},
						{"Torso", "Left Leg"},
						{"Torso", "Right Leg"}
					}
				end
				for _, conn in ipairs(skeletonConnections) do
					local line = skeletonLines[conn[1] .. "-" .. conn[2]]
					if line then
						local part1 = char:FindFirstChild(conn[1])
						local part2 = char:FindFirstChild(conn[2])
						if part1 and part2 then
							local pos1, onScreen1 = workspace.CurrentCamera:WorldToViewportPoint(part1.Position)
							local pos2, onScreen2 = workspace.CurrentCamera:WorldToViewportPoint(part2.Position)
							if onScreen1 and onScreen2 then
								line.From = Vector2.new(pos1.X, pos1.Y)
								line.To = Vector2.new(pos2.X, pos2.Y)
								line.Visible = true
							else
								line.Visible = false
							end
						else
							line.Visible = false
						end
					end
				end
			else
				-- Character no longer exists, hide all lines
				for _, line in pairs(skeletonLines) do
					line.Visible = false
				end
			end
		end
	end

	refreshAllESP = function()
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= player then
				refreshPlayerESP(plr)
			end
		end
	end

	local visualConnection = nil
	local function setVisualMode()
		if visualConnection then
			visualConnection:Disconnect()
			visualConnection = nil
		end

		local function updateVisuals(dt)
			-- Keep RGB engine always running so colors do not stall when menu visibility changes.
			local now = tick()
			local currentCamera = workspace.CurrentCamera or (aimState and aimState.camera)
			if currentCamera then
				if cameraFovState.default == nil then
					cameraFovState.default = currentCamera.FieldOfView
				end
				currentCamera.FieldOfView = cameraFovState.value
			end
			visualState.hue = (now * 0.18) % 1
			visualState.pulse = 0.72 + 0.28 * math.sin(now * 8)
			visualState.currentRgbColor = Color3.fromHSV(visualState.hue, 1, visualState.pulse)

			if mainFrame and mainFrame.Parent then
				mainStroke.Color = visualState.currentRgbColor
				usernameStroke.Color = visualState.currentRgbColor
				for _, stroke in ipairs(tabStrokes) do
					stroke.Color = visualState.currentRgbColor
				end
			end

			-- Update active checkbox fills and strokes to RGB
			for fill, _ in pairs(rgbFills) do
				if fill and fill.Parent then
					fill.BackgroundColor3 = visualState.currentRgbColor
				else
					rgbFills[fill] = nil
				end
			end
			for stroke, _ in pairs(rgbStrokes) do
				if stroke and stroke.Parent then
					stroke.Color = visualState.currentRgbColor
				else
					rgbStrokes[stroke] = nil
				end
			end

			-- Update ESP highlights, neon parts, and skeleton colors
			for _, highlight in pairs(espState.glows) do
				if highlight and highlight.Parent then
					highlight.FillColor = visualState.currentRgbColor
					highlight.OutlineColor = visualState.currentRgbColor
				end
			end
			for _, parts in pairs(espState.boxes) do
				for part, _ in pairs(parts) do
					if part and part.Parent then
						part.Color = visualState.currentRgbColor
					end
				end
			end
			for _, skeletonLines in pairs(espState.skeletons) do
				if type(skeletonLines) == "table" then
					for _, line in pairs(skeletonLines) do
					line.Color = visualState.currentRgbColor
					end
				end
			end

			-- Update grok watermark RGB
			if grokMark and grokMark.Parent then
				grokMark.TextColor3 = visualState.currentRgbColor
				grokMark.TextTransparency = 0.05 + 0.12 * math.sin(now * 3.5)
			end

			-- Update weapon chams part colors; pulse highlight glow
			for part, _ in pairs(chamsBoxes) do
				if part and part.Parent then
					part.Color = visualState.currentRgbColor
				end
			end
			for obj, h in pairs(chamsHighlights) do
				if h and h.Parent then
					h.FillColor = visualState.currentRgbColor
					h.OutlineColor = visualState.currentRgbColor
					h.FillTransparency = 0.38 + 0.28 * math.sin(now * 7 + 1.2)
					h.OutlineTransparency = 0
				else
					chamsHighlights[obj] = nil
				end
			end

			-- Only process ESP if data is ready
			if not player or not player.Character then return end

			local toRemove = {}

			for character, espData in pairs(espState.guis) do
				if not character or not character.Parent then
					table.insert(toRemove, character)
				else
					local owner = Players:GetPlayerFromCharacter(character)
					
					if not owner then
						table.insert(toRemove, character)
					elseif isSameTeam(owner) then
						table.insert(toRemove, character)   -- same team -> hide/remove ESP
					else
						local gui = type(espData) == "table" and espData.gui or espData
						if gui and gui.Parent then
							-- Update size for constant apparent size
							local root = gui.Adornee
							if root and currentCamera then
								local distance = (currentCamera.CFrame.Position - root.Position).Magnitude
								local scale = math.max(distance * 0.1, 1)  -- minimum 1 to avoid too small
								gui.Size = UDim2.new(scale, 0, scale * 1.4, 0)
							end

							-- Enemy only: apply rainbow to brackets and name
							for _, obj in ipairs(gui:GetChildren()) do
								if obj:IsA("TextLabel") and obj ~= espData.distanceLabel then
									obj.TextColor3 = visualState.currentRgbColor
									for _, stroke in ipairs(obj:GetChildren()) do
										if stroke:IsA("UIStroke") then
											stroke.Color = visualState.currentRgbColor
										end
									end
								end
							end

							if espState.glows[character] then
								espState.glows[character].FillColor = visualState.currentRgbColor
								espState.glows[character].OutlineColor = visualState.currentRgbColor
							end
							
							-- Update neon chams colors for enemy parts
							if espState.boxes[character] then
								for part, _ in pairs(espState.boxes[character]) do
									if part and part.Parent then
										part.Color = visualState.currentRgbColor
									end
								end
							end
						end
					end
				end
			end

			-- Update ESP info (health, distance)
			updateESPInfo()

			-- Safe cleanup
			for _, character in ipairs(toRemove) do
				removeCharacterESP(character)
			end
		end

		visualModeStatus.Text = "Visual Loop: Internal (RenderStepped)"
		visualConnection = RunService.RenderStepped:Connect(updateVisuals)
	end

	setVisualMode()

	widerFOVRenderConnection = "GangstaCameraFOVLock"
	pcall(function()
		RunService:UnbindFromRenderStep(widerFOVRenderConnection)
	end)
	if cameraFovState.cameraSignal then
		cameraFovState.cameraSignal:Disconnect()
		cameraFovState.cameraSignal = nil
	end
	if cameraFovState.cameraSwapSignal then
		cameraFovState.cameraSwapSignal:Disconnect()
		cameraFovState.cameraSwapSignal = nil
	end
	local function enforceCameraFov()
		local currentCamera = workspace.CurrentCamera
		if not currentCamera then
			return
		end
		if cameraFovState.default == nil then
			cameraFovState.default = currentCamera.FieldOfView
		end
		if cameraFovState.boundCamera ~= currentCamera then
			cameraFovState.boundCamera = currentCamera
			if cameraFovState.cameraSignal then
				cameraFovState.cameraSignal:Disconnect()
				cameraFovState.cameraSignal = nil
			end
			cameraFovState.cameraSignal = currentCamera:GetPropertyChangedSignal("FieldOfView"):Connect(function()
				local cam = workspace.CurrentCamera
				if cam and math.abs(cam.FieldOfView - cameraFovState.value) > 0.01 then
					cam.FieldOfView = cameraFovState.value
				end
			end)
		end
		if math.abs(currentCamera.FieldOfView - cameraFovState.value) > 0.01 then
			currentCamera.FieldOfView = cameraFovState.value
		end
	end
	enforceCameraFov()
	cameraFovState.cameraSwapSignal = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(enforceCameraFov)
	RunService:BindToRenderStep(widerFOVRenderConnection, Enum.RenderPriority.Last.Value, enforceCameraFov)

	task.spawn(function()
		while screenGui and screenGui.Parent do
			task.wait(2)
			if (not visualConnection) or (not visualConnection.Connected) then
				setVisualMode()
			end
		end
	end)

	-- =============== WEAPON CHAMS SYSTEM ===============
	-- (chamsEnabled, chamsBoxes, constants declared earlier so setVisualMode captures them correctly)

	-- Arsenal auto-detection by PlaceId
	local isArsenal = game.PlaceId == 286090429

	-- Arm part name patterns used in Arsenal viewmodels
	local ARM_PATTERNS = {
		"arm", "hand", "sleeve", "glove", "forearm",
		"elbow", "wrist", "finger", "palm",
	}

	local CHAMS_NAME_KEYWORDS = {
		"weapon", "gun", "rifle", "pistol", "deagle", "revolver", "smg", "shotgun", "sniper",
		"lmg", "minigun", "launcher", "rocket", "rpg", "grenade", "projectile", "bullet", "ammo",
		"shell", "casing", "cartridge", "tracer", "muzzle", "missile", "dart", "bolt", "arrow",
		"pellet", "slug", "fireball", "orb", "plasma", "beam", "flare", "molotov", "explosive",
	}

	local CHAMS_WORLD_CONTAINER_HINTS = {
		"projectile", "projectiles", "bullet", "bullets", "ammo", "effects", "fx", "visual", "particles",
		"workspace", "client", "ignore", "misc", "temporary", "debris",
	}

	local chamsConnections = {}
	chamsBoxes = chamsState.boxes
	chamsHighlights = {}
	local CHAMS_GLOW_NAME = "GangstaChamsGlow"
	local chamsWatchedInstances = {}

	local function nameHasKeyword(name)
		local lowered = string.lower(name or "")
		for _, keyword in ipairs(CHAMS_NAME_KEYWORDS) do
			if string.find(lowered, keyword, 1, true) then
				return true
			end
		end
		return false
	end

	local function instanceChainHasKeyword(inst, depth)
		local cur = inst
		for _ = 1, (depth or 6) do
			if not cur then break end
			if nameHasKeyword(cur.Name) then
				return true
			end
			cur = cur.Parent
		end
		return false
	end

	local function isProjectileLikePart(part)
		if not part or not part:IsA("BasePart") then return false end

		if nameHasKeyword(part.Name) or instanceChainHasKeyword(part.Parent, 5) then
			return true
		end

		if part:FindFirstChildOfClass("Trail") or part:FindFirstChildOfClass("Beam") then
			return true
		end

		for _, desc in ipairs(part:GetChildren()) do
			if desc:IsA("ParticleEmitter") or desc:IsA("Smoke") or desc:IsA("Fire") then
				return true
			end
		end

		local velocity = part.AssemblyLinearVelocity
		if velocity and velocity.Magnitude >= 70 then
			return true
		end

		local size = part.Size
		local maxDim = math.max(size.X, size.Y, size.Z)
		local minDim = math.min(size.X, size.Y, size.Z)
		if maxDim <= 1.8 and minDim <= 0.35 and part.Transparency <= 0.95 then
			return true
		end

		return false
	end

	local function shouldChamsPart(part, sourceTag)
		if not part or not part:IsA("BasePart") then return false end
		if part.Transparency >= 0.995 then return false end
		if part.Name == "HumanoidRootPart" then return false end

		if sourceTag == "camera" then
			return true
		end

		if sourceTag == "character" then
			return instanceChainHasKeyword(part, 6) or isArsenal
		end

		return isProjectileLikePart(part)
	end

	local function shouldWatchWorldObject(inst)
		if not inst then return false end
		if not (inst:IsA("Model") or inst:IsA("Tool") or inst:IsA("Folder") or inst:IsA("BasePart")) then
			return false
		end

		local lowered = string.lower(inst.Name)
		for _, hint in ipairs(CHAMS_WORLD_CONTAINER_HINTS) do
			if string.find(lowered, hint, 1, true) then
				return true
			end
		end

		if inst:IsA("BasePart") and isProjectileLikePart(inst) then
			return true
		end

		return nameHasKeyword(inst.Name)
	end

	local function isArmPart(part)
		local cur = part
		for _ = 1, 6 do
			if not cur or not cur:IsA("Instance") then break end
			local n = cur.Name:lower()
			if n == "arms" then return true end
			for _, pat in ipairs(ARM_PATTERNS) do
				if n:find(pat, 1, true) then return true end
			end
			cur = cur.Parent
		end
		return false
	end

	local function applyChamsToPart(part, sourceTag)
		if chamsBoxes[part] then return end
		if not shouldChamsPart(part, sourceTag) then return end

		local asArm = (sourceTag == "camera") and (isArsenal and isArmPart(part))

		-- Remove any legacy chams light aura so the character/weapon does not emit radius glow.
		local legacyGlow = part:FindFirstChild(CHAMS_GLOW_NAME)
		if legacyGlow then
			legacyGlow:Destroy()
		end

		-- Store original appearance so we can fully restore it
		local orig = {
			Color        = part.Color,
			Material     = part.Material,
			Transparency = part.Transparency,
			CastShadow   = part.CastShadow,
		}
		chamsBoxes[part] = orig

		-- Apply chams: Neon material makes the part self-illuminate with the chosen color
		part.Material     = Enum.Material.Neon
		part.Color        = visualState.currentRgbColor
		part.CastShadow   = false
		if asArm then
			-- Arms: keep fully opaque and crisp without extra light bloom.
			part.Transparency = 0
		elseif sourceTag == "world" then
			-- World projectiles/ammo: slightly transparent so trails are visible without eye strain.
			part.Transparency = math.max(0.12, math.min(part.Transparency, 0.28))
		else
			-- Weapons/viewmodels: keep solid and bright.
			part.Transparency = 0
		end
	end

	local function applyChamsToObject(obj, sourceTag)
		-- Add a persistent RGB highlight glow around the whole model/tool
		if (obj:IsA("Model") or obj:IsA("Tool")) and not chamsHighlights[obj] then
			local h = Instance.new("Highlight")
			h.Name = "GangstaChamsHighlight"
			h.FillColor = visualState.currentRgbColor
			h.OutlineColor = visualState.currentRgbColor
			h.FillTransparency = 0.55
			h.OutlineTransparency = 0
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.Parent = obj
			chamsHighlights[obj] = h
		end
		if obj:IsA("BasePart") then
			applyChamsToPart(obj, sourceTag)
		end
		for _, desc in ipairs(obj:GetDescendants()) do
			if desc:IsA("BasePart") then
				applyChamsToPart(desc, sourceTag)
			end
		end
	end

	local function restorePartChams(part)
		local orig = chamsBoxes[part]
		if not orig then return end
		if part and part.Parent then
			part.Color        = orig.Color
			part.Material     = orig.Material
			part.Transparency = orig.Transparency
			part.CastShadow   = orig.CastShadow
			local legacyGlow = part:FindFirstChild(CHAMS_GLOW_NAME)
			if legacyGlow then
				legacyGlow:Destroy()
			end
		end
		chamsBoxes[part] = nil
	end

	local function removeChamsFromObject(obj)
		if chamsHighlights[obj] then
			pcall(function() chamsHighlights[obj]:Destroy() end)
			chamsHighlights[obj] = nil
		end
		restorePartChams(obj)
		for _, desc in ipairs(obj:GetDescendants()) do
			restorePartChams(desc)
		end
	end

	local function clearChams()
		for obj, h in pairs(chamsHighlights) do
			if h and h.Parent then
				pcall(function() h:Destroy() end)
			end
		end
		chamsHighlights = {}
		for part, _ in pairs(chamsBoxes) do
			restorePartChams(part)
		end
		chamsBoxes = {}
	end

	local function disconnectChams()
		for _, conn in ipairs(chamsConnections) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		chamsConnections = {}
		chamsWatchedInstances = {}
	end

	local function watchObjectForChams(obj, sourceTag)
		if not obj or chamsWatchedInstances[obj] then return end
		if not (obj:IsA("Model") or obj:IsA("Tool") or obj:IsA("Folder") or obj:IsA("BasePart")) then return end
		chamsWatchedInstances[obj] = true

		task.defer(function()
			if chamsState.enabled and obj and obj.Parent then
				applyChamsToObject(obj, sourceTag)
			end
		end)

		chamsConnections[#chamsConnections + 1] = obj.DescendantAdded:Connect(function(desc)
			if chamsState.enabled and desc:IsA("BasePart") then
				applyChamsToPart(desc, sourceTag)
			end
		end)

		chamsConnections[#chamsConnections + 1] = obj.AncestryChanged:Connect(function(_, parent)
			if not parent then
				chamsWatchedInstances[obj] = nil
			end
		end)
	end

	local function enableChams()
		disconnectChams()
		clearChams()

		local cam = workspace.CurrentCamera
		if cam then
			for _, child in ipairs(cam:GetChildren()) do
				watchObjectForChams(child, "camera")
			end

			chamsConnections[#chamsConnections + 1] = cam.ChildAdded:Connect(function(child)
				watchObjectForChams(child, "camera")
			end)
			chamsConnections[#chamsConnections + 1] = cam.ChildRemoved:Connect(removeChamsFromObject)
		end

		local char = player.Character
		if char then
			for _, child in ipairs(char:GetChildren()) do
				if child:IsA("Tool") then
					watchObjectForChams(child, "character")
				end
			end
			chamsConnections[#chamsConnections + 1] = char.ChildAdded:Connect(function(child)
				if child:IsA("Tool") then
					watchObjectForChams(child, "character")
				end
			end)
			chamsConnections[#chamsConnections + 1] = char.ChildRemoved:Connect(function(child)
				if child:IsA("Tool") then
					removeChamsFromObject(child)
				end
			end)
		end

		for _, child in ipairs(workspace:GetChildren()) do
			if child ~= cam and child ~= player.Character and shouldWatchWorldObject(child) then
				watchObjectForChams(child, "world")
			end
		end

		chamsConnections[#chamsConnections + 1] = workspace.ChildAdded:Connect(function(child)
			if child ~= workspace.CurrentCamera and child ~= player.Character and shouldWatchWorldObject(child) then
				watchObjectForChams(child, "world")
			end
		end)

		chamsConnections[#chamsConnections + 1] = workspace.ChildRemoved:Connect(removeChamsFromObject)
	end

	local function disableChams()
		disconnectChams()
		clearChams()
	end

	chamsToggle.MouseButton1Click:Connect(function()
		chamsState.enabled = not chamsState.enabled
		setChamsCheck(chamsState.enabled)
		if chamsState.enabled then
			enableChams()
		else
			disableChams()
		end
	end)

	player.CharacterAdded:Connect(function()
		if chamsState.enabled then
			disconnectChams()
			clearChams()
			task.wait(0.5)
			enableChams()
		end
	end)

	-- =============== ESP SYSTEM ===============

	createCornerESP = function(character)
		if not character then return end
		local rootPart = getCharacterRoot(character)
		if not rootPart then return end
		
		-- Get owner and validate
		local owner = Players:GetPlayerFromCharacter(character)
		if not owner then return end
		if owner == player then return end
		
		-- STRICT GUARD: Do NOT create ESP if teammate
		if isSameTeam(owner) then return end
		
		-- Check if ESP already exists for this character
		if espState.glows[character] then return end
		
		-- Create glow highlight for enemy
		if not espState.glows[character] then
			pcall(function()
				local highlight = Instance.new("Highlight")
				highlight.Parent = character
				highlight.FillColor = visualState.currentRgbColor
				highlight.OutlineColor = visualState.currentRgbColor
				highlight.FillTransparency = 0.3
				highlight.OutlineTransparency = 0
				highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				espState.glows[character] = highlight
			end)
		end
		
		-- Apply neon chams to enemy parts
		if not espState.boxes[character] then
			espState.boxes[character] = {}
			for _, desc in ipairs(character:GetDescendants()) do
				if desc:IsA("BasePart") and desc.Transparency < 0.999 and desc.Name ~= "HumanoidRootPart" then
					espState.boxes[character][desc] = {
						Color = desc.Color,
						Material = desc.Material,
						Transparency = desc.Transparency,
						CastShadow = desc.CastShadow
					}
					desc.Material = Enum.Material.Neon
					desc.Color = visualState.currentRgbColor
					desc.CastShadow = false
					desc.Transparency = 0
				end
			end
		end
		
		-- Watch for new parts added to enemy character
		espState.charConnections[character] = {}
		table.insert(espState.charConnections[character], character.DescendantAdded:Connect(function(desc)
			if desc:IsA("BasePart") and desc.Transparency < 0.999 and desc.Name ~= "HumanoidRootPart" then
				if not espState.boxes[character][desc] then
					espState.boxes[character][desc] = {
						Color = desc.Color,
						Material = desc.Material,
						Transparency = desc.Transparency,
						CastShadow = desc.CastShadow
					}
					desc.Material = Enum.Material.Neon
					desc.Color = visualState.currentRgbColor
					desc.CastShadow = false
					desc.Transparency = 0
				end
			end
		end))
		
		-- Create skeleton lines
		if not espState.skeletons[character] then
			espState.skeletons[character] = {}
			local isR15 = character:FindFirstChild("UpperTorso") ~= nil
			local skeletonConnections
			if isR15 then
				skeletonConnections = {
					{"Head", "UpperTorso"},
					{"UpperTorso", "LowerTorso"},
					{"LowerTorso", "LeftUpperLeg"},
					{"LowerTorso", "RightUpperLeg"},
					{"LeftUpperLeg", "LeftLowerLeg"},
					{"LeftLowerLeg", "LeftFoot"},
					{"RightUpperLeg", "RightLowerLeg"},
					{"RightLowerLeg", "RightFoot"},
					{"UpperTorso", "LeftUpperArm"},
					{"UpperTorso", "RightUpperArm"},
					{"LeftUpperArm", "LeftLowerArm"},
					{"LeftLowerArm", "LeftHand"},
					{"RightUpperArm", "RightLowerArm"},
					{"RightLowerArm", "RightHand"}
				}
			else
				skeletonConnections = {
					{"Head", "Torso"},
					{"Torso", "Left Arm"},
					{"Torso", "Right Arm"},
					{"Torso", "Left Leg"},
					{"Torso", "Right Leg"}
				}
			end
			for _, conn in ipairs(skeletonConnections) do
				local line = Drawing.new("Line")
				line.Visible = false
				line.Color = visualState.currentRgbColor
				line.Thickness = 3
				line.Transparency = 1
				line.ZIndex = 1000
				espState.skeletons[character][conn[1] .. "-" .. conn[2]] = line
			end
		end
	end

	removeCharacterESP = function(character)
		if not character then return end
		
		-- Remove glow safely
		if espState.glows[character] then
			pcall(function() espState.glows[character]:Destroy() end)
			espState.glows[character] = nil
		end
		
		-- Remove skeleton lines safely
		if espState.skeletons[character] then
			for _, line in pairs(espState.skeletons[character]) do
				pcall(function() line:Remove() end)
			end
			espState.skeletons[character] = nil
		end
	end

	local function setupPlayerESP(plr)
		-- Clean up any previous connections for this player
		if espState.connections[plr] then
			for _, conn in ipairs(espState.connections[plr]) do
				pcall(function() conn:Disconnect() end)
			end
			espState.connections[plr] = nil
		end

		local conns = {}

		-- Cleanup on death / character leaving
		conns[#conns + 1] = plr.CharacterRemoving:Connect(function(char)
			removeCharacterESP(char)
		end)

		-- Re-apply on respawn without assuming team/character load order
		conns[#conns + 1] = plr.CharacterAdded:Connect(function(char)
			task.spawn(function()
				for _ = 1, 30 do
					if not espState.enabled or plr.Character ~= char or not char.Parent then
						return
					end
					refreshPlayerESP(plr)
					-- Do not exit just because root exists; owner/team mapping can still be settling.
					if isSameTeam(plr) or espState.glows[char] ~= nil then
						return
					end
					task.wait(0.1)
				end
			end)
		end)

		-- Watch for team changes and reconcile ESP immediately
		conns[#conns + 1] = plr.Changed:Connect(function(prop)
			if prop == "Team" or prop == "TeamColor" or prop == "Neutral" then
				refreshPlayerESP(plr)
			end
		end)

		espState.connections[plr] = conns

		refreshPlayerESP(plr)
	end

	local function teardownPlayerESP(plr)
		-- Disconnect all connections safely
		if espState.connections[plr] then
			for _, conn in ipairs(espState.connections[plr]) do
				pcall(function() conn:Disconnect() end)
			end
			espState.connections[plr] = nil
		end
		
		-- Remove character ESP safely
		if plr.Character then
			removeCharacterESP(plr.Character)
		end
	end

	local function enableESP()
		-- Register all players immediately; team checks no longer depend on spawn timing
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= player then
				setupPlayerESP(plr)
			end
		end
	end

	local function disableESP()
		-- Disconnect ALL player connections safely
		for _, conns in pairs(espState.connections) do
			for _, conn in ipairs(conns) do
				if conn then
					pcall(function() conn:Disconnect() end)
				end
			end
		end
		
		-- Destroy ALL glow highlights safely
		for _, glow in pairs(espState.glows) do
			if glow then
				pcall(function() glow:Destroy() end)
			end
		end
		
		-- Restore ALL neon chams safely
		for _, parts in pairs(espState.boxes) do
			for part, orig in pairs(parts) do
				if part and part.Parent then
					part.Color = orig.Color
					part.Material = orig.Material
					part.Transparency = orig.Transparency
					part.CastShadow = orig.CastShadow
				end
			end
		end
		
		-- Disconnect ALL character connections safely
		for _, conns in pairs(espState.charConnections) do
			for _, conn in ipairs(conns) do
				if conn then
					pcall(function() conn:Disconnect() end)
				end
			end
		end
		
		-- Hide ALL skeleton lines
		for _, skeletonLines in pairs(espState.skeletons) do
			if type(skeletonLines) == "table" then
				for _, line in pairs(skeletonLines) do
					pcall(function() line.Visible = false end)
				end
			end
		end
		
		-- Clear all tables completely
		espState.connections = {}
		espState.glows = {}
		espState.boxes = {}
		espState.skeletons = {}
		espState.charConnections = {}
	end

	-- =============== TOGGLE HANDLERS ===============
	espToggle.MouseButton1Click:Connect(function()
		local success, result = safeExecute(function()
			espState.enabled = not espState.enabled
			setEspCheck(espState.enabled)
			if espState.enabled then
				enableESP()
			else
				disableESP()
			end
		end, "ESP_TOGGLE")

		if not success then
			logError("ESP", "Toggle operation failed", nil, result)
			-- Reset state on failure
			espState.enabled = not espState.enabled
			setEspCheck(espState.enabled)
		end
	end)

	-- ESP lifecycle hooks for players joining/leaving during runtime.
	Players.PlayerAdded:Connect(function(plr)
		if espState.enabled and plr ~= player then
			setupPlayerESP(plr)
		end
	end)

	Players.PlayerRemoving:Connect(function(plr)
		teardownPlayerESP(plr)
	end)

	player.CharacterAdded:Connect(function()
		task.spawn(function()
			for _ = 1, 20 do
				if not espState.enabled then
					return
				end
				refreshAllESP()
				task.wait(0.1)
			end
		end)
	end)

	player.Changed:Connect(function(prop)
		if prop == "Team" or prop == "TeamColor" or prop == "Neutral" then
			task.defer(refreshAllESP)
		end
	end)

	-- =============== AIMBOT TARGETING SYSTEM ===============
	local aimState = {
		enabled = false,
		isRMBDown = false,
		isLMBDown = false,
		camera = workspace.CurrentCamera,
	}
	do
	local fovCircle = Drawing.new("Circle")
	fovCircle.Visible = false
	fovCircle.Radius = aimbotFOV
	fovCircle.Color = Color3.fromRGB(255, 255, 255)
	fovCircle.Thickness = 2
	fovCircle.Filled = false
	fovCircle.Transparency = 1
	fovCircle.NumSides = 64
	aimDraw.fovCircle = fovCircle

	local crosshairH = Drawing.new("Line")
	crosshairH.Visible = false
	crosshairH.Color = Color3.fromRGB(255, 255, 255)
	crosshairH.Thickness = 2
	crosshairH.Transparency = 1

	local crosshairV = Drawing.new("Line")
	crosshairV.Visible = false
	crosshairV.Color = Color3.fromRGB(255, 255, 255)
	crosshairV.Thickness = 2
	crosshairV.Transparency = 1

	local crosshairHGlow = Drawing.new("Line")
	crosshairHGlow.Visible = false
	crosshairHGlow.Color = Color3.fromRGB(255, 255, 255)
	crosshairHGlow.Thickness = 4
	crosshairHGlow.Transparency = 0.3

	local crosshairVGlow = Drawing.new("Line")
	crosshairVGlow.Visible = false
	crosshairVGlow.Color = Color3.fromRGB(255, 255, 255)
	crosshairVGlow.Thickness = 4
	crosshairVGlow.Transparency = 0.3
	aimDraw.crosshairH = crosshairH
	aimDraw.crosshairV = crosshairV
	aimDraw.crosshairHGlow = crosshairHGlow
	aimDraw.crosshairVGlow = crosshairVGlow

	local snapLine = Drawing.new("Line")
	snapLine.Visible = false
	snapLine.Color = Color3.fromRGB(255, 0, 80)
	snapLine.Thickness = 1.5
	snapLine.Transparency = 1
	aimDraw.snapLine = snapLine

	aimDraw.gunIndicator = Drawing.new("Circle")
	aimDraw.gunIndicator.Visible = false
	aimDraw.gunIndicator.Radius = 8
	aimDraw.gunIndicator.Color = Color3.fromRGB(0, 255, 0)
	aimDraw.gunIndicator.Thickness = 2
	aimDraw.gunIndicator.Filled = true
	aimDraw.gunIndicator.Transparency = 0.7

	function getScreenCenter()
		local camera = workspace.CurrentCamera
		local viewportSize = camera and camera.ViewportSize or Vector2.new(0, 0)
		return Vector2.new(viewportSize.X / 2, viewportSize.Y / 2)
	end

	function hideAimDrawings()
		fovCircle.Visible = false
		snapLine.Visible = false
		crosshairH.Visible = false
		crosshairV.Visible = false
		crosshairHGlow.Visible = false
		crosshairVGlow.Visible = false
		if aimDraw.gunIndicator then
			aimDraw.gunIndicator.Visible = false
		end
	end

	function isTargetVisible(targetChar)
		if not targetChar or not targetChar.Parent then return false end
		local head = targetChar:FindFirstChild("Head")
		if not head then return false end

		local cam = workspace.CurrentCamera or aimState.camera
		if not cam then return false end
		local origin = cam.CFrame.Position
		local headPos = head.Position
		local direction = headPos - origin
		if direction.Magnitude <= 0 then return false end

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local filter = {}
		if player.Character then
			filter[#filter + 1] = player.Character
		end
		if workspace.CurrentCamera then
			filter[#filter + 1] = workspace.CurrentCamera
		end
		params.FilterDescendantsInstances = filter

		local result = workspace:Raycast(origin, direction, params)
		if not result then
			return true  -- No obstruction
		end

		if result.Instance:IsDescendantOf(targetChar) then
			return true  -- Hit the target itself
		end

		return false  -- Obstructed
	end

	function getClosestHeadInFOV()
		local center = getScreenCenter()
		local closestDist = math.huge
		local closestHead = nil

		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= player and not isSameTeam(plr) and plr.Character and isCharacterAlive(plr.Character) then
				local head = plr.Character:FindFirstChild("Head")
				if head then
					local screenPos, onScreen = aimState.camera:WorldToViewportPoint(head.Position)
					if onScreen then
						local dist = (Vector2.new(screenPos.X, screenPos.Y) - center).Magnitude
						if dist < aimbotFOV and dist < closestDist and isTargetVisible(plr.Character) then
							closestDist = dist
							closestHead = head
						end
					end
				end
			end
		end

		return closestHead
	end


	RunService.RenderStepped:Connect(function()
		if not aimState.enabled then
			hideAimDrawings()
			return
		end

		local center = getScreenCenter()
		local hasVisualLock = false

		-- Update circle position and size
		fovCircle.Position = center
		fovCircle.Radius = aimbotFOV
		fovCircle.Visible = true

		-- Update crosshair
		local crossSize = crosshairSettings.size
		crosshairH.Thickness = crosshairSettings.thickness
		crosshairV.Thickness = crosshairSettings.thickness
		crosshairHGlow.Thickness = crosshairSettings.glowThickness
		crosshairVGlow.Thickness = crosshairSettings.glowThickness
		crosshairH.From = Vector2.new(center.X - crossSize, center.Y)
		crosshairH.To = Vector2.new(center.X + crossSize, center.Y)
		crosshairV.From = Vector2.new(center.X, center.Y - crossSize)
		crosshairV.To = Vector2.new(center.X, center.Y + crossSize)
		crosshairH.Visible = true
		crosshairV.Visible = true

		-- Update crosshair glow
		crosshairHGlow.From = Vector2.new(center.X - crossSize, center.Y)
		crosshairHGlow.To = Vector2.new(center.X + crossSize, center.Y)
		crosshairVGlow.From = Vector2.new(center.X, center.Y - crossSize)
		crosshairVGlow.To = Vector2.new(center.X, center.Y + crossSize)
		crosshairHGlow.Visible = true
		crosshairVGlow.Visible = true

		local target = getClosestHeadInFOV()
		if target then
			hasVisualLock = true
			local screenPos = aimState.camera:WorldToViewportPoint(target.Position)
			snapLine.From = center
			snapLine.To = Vector2.new(screenPos.X, screenPos.Y)
			snapLine.Visible = true
			-- Debug output for troubleshooting
			if _G.DEBUG_SNAPLINE then
				print("[Snapline] Drawing from center:", center, "to:", Vector2.new(screenPos.X, screenPos.Y))
			end
			-- Optionally lock camera if RMB/LMB is down
			if aimState.isRMBDown or aimState.isLMBDown then
				aimState.camera.CFrame = CFrame.new(aimState.camera.CFrame.Position, target.Position)
			end
		else
			snapLine.Visible = false
		end

		local rgbNow = visualState.currentRgbColor
		local lockColor = Color3.fromRGB(255, 50, 50)
		local circleColor = hasVisualLock and lockColor or Color3.fromRGB(255, 255, 255)

		-- Apply color and effects
		fovCircle.Color = rgbNow
		fovCircle.Thickness = hasVisualLock and 3.2 or 2.2
		fovCircle.Transparency = 1

		-- Crosshair colors
		crosshairH.Color = rgbNow
		crosshairV.Color = rgbNow
		crosshairH.Transparency = hasVisualLock and 1 or crosshairSettings.opacity
		crosshairV.Transparency = hasVisualLock and 1 or crosshairSettings.opacity

		-- Crosshair glow colors
		crosshairHGlow.Color = rgbNow
		crosshairVGlow.Color = rgbNow
		crosshairHGlow.Transparency = hasVisualLock and math.clamp(crosshairSettings.glowOpacity + 0.2, 0, 1) or crosshairSettings.glowOpacity
		crosshairVGlow.Transparency = hasVisualLock and math.clamp(crosshairSettings.glowOpacity + 0.2, 0, 1) or crosshairSettings.glowOpacity

		-- Snap line tracks RGB (always visible when target found)
		if hasVisualLock then
			snapLine.Color = rgbNow
			snapLine.Thickness = 2.5
			snapLine.Transparency = 0.9
		else
			snapLine.Thickness = 1.5
			snapLine.Transparency = 0.7
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gp)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			aimState.isLMBDown = true
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			aimState.isRMBDown = true
			return
		end
		if gp then return end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			aimState.isLMBDown = false
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			aimState.isRMBDown = false
		end
	end)

	aimToggle.MouseButton1Click:Connect(function()
		local success, result = safeExecute(function()
			aimState.enabled = not aimState.enabled
			setAimCheck(aimState.enabled)
			if aimState.enabled then
				local camera = workspace.CurrentCamera
				if not camera then
					logError("AIMBOT", "CurrentCamera not available", nil, nil)
					return
				end
				local center = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
				fovCircle.Position = center
				fovCircle.Radius = aimbotFOV
				fovCircle.Visible = true
				logCommand("AIMBOT", true, "Enabled", 0)
			else
				hideAimDrawings()
				logCommand("AIMBOT", true, "Disabled", 0)
			end
		end, "AIMBOT_TOGGLE")

		if not success then
			logError("AIMBOT", "Toggle operation failed", nil, result)
			-- Reset state on failure
			aimState.enabled = not aimState.enabled
			setAimCheck(aimState.enabled)
		end
	end)

	hideAimDrawings()
	end

	-- =============== FIRE RATE SYSTEM STATE (ARSENAL/FPS OPTIMIZED) ===============
	fireRateState = {
		enabled = false,
		shootConnection = nil,
		gunDetectConnection = nil,
		overrideConnections = {},
		originalWeaponValues = {},
		currentTool = nil,
		lastShotTime = 0,
		shootRate = 0.008  -- Minimum delay between synthetic shots (seconds)
	}

	local alwaysAutoState = {
		enabled = false
	}

	local flashState = {
		enabled = false,
		connection = nil,
		speed = 150
	}

	local longMeleeState = {
		enabled = false,
		originalValues = {},
		originalAttributes = {},
		connections = {}
	}

	local toggleLongMelee

	noRecoilState = {
		enabled = false,
		originalValues = {},
		connection = nil,
		aggressiveConnection = nil,
		cameraHook = nil,
		humanoidHook = nil,
		backpackHook = nil,
		characterHook = nil,
		toolHooks = {},
		originalCameraCFrame = nil,
		trackedValues = {},
		trackedLookup = {},
		valueConnections = {},
		rootConnections = {},
		rootConnectionList = {},
		applyCursor = 0,
		lastTickTime = 0,
		lastRescanTime = 0,
		avgDt = 0,
		applyInterval = 0.08,
		baseApplyInterval = 0.08,
		rescanInterval = 1.25,
		maxPerTick = 200
	}

	local flyState = {
		enabled = false,
		isSpaceDown = false,
		velocityConnection = nil,
		forward = false,
		back = false,
		left = false,
		right = false,
		up = false,
		down = false,
		boost = false,
		speed = 62,
		boostMultiplier = 1.6,
		lastHumanoid = nil,
	}

	local killAllState = {
		enabled = false,
		connection = nil,
		targetPlayer = nil,
		lastAcquire = 0,
		lastAttack = 0,
		acquireInterval = 0.08,
		attackInterval = 0.09,
		behindDistance = 3.2,
		heightOffset = 8.2,
		sideOffset = 1.1,
		cameraAimHeight = 1.25,
		orbitSide = 1,
		lastHumanoid = nil,
		spawnConnections = {},
		spawnProtectionCache = {
			entries = {},
			lastRefresh = 0,
			refreshInterval = 2.5,
		},
	}

	killAllState.isKillAllMeleeTool = function(tool)
		if not tool then
			return false
		end

		local nameLower = string.lower(tool.Name or "")
		local meleeKeywords = {
			"melee", "knife", "sword", "blade", "katana", "machete", "bat",
			"hammer", "fist", "axe", "spear", "dagger", "crowbar", "club",
			"shovel", "pickaxe", "wrench", "scythe", "lance", "halberd",
			"staff", "cane", "stick", "pipe", "bottle",
		}

		for _, keyword in ipairs(meleeKeywords) do
			if string.find(nameLower, keyword, 1, true) ~= nil then
				return true
			end
		end

		return false
	end

	killAllState.refreshKillAllSpawnProtectionCache = function()
		if not isArsenal then
			killAllState.spawnProtectionCache.entries = {}
			killAllState.spawnProtectionCache.lastRefresh = tick()
			return
		end

		local now = tick()
		local cache = killAllState.spawnProtectionCache
		if (now - cache.lastRefresh) < cache.refreshInterval and #cache.entries > 0 then
			return
		end

		local protected = {}
		for _, inst in ipairs(workspace:GetDescendants()) do
			if inst:IsA("SpawnLocation") then
				protected[#protected + 1] = inst
			elseif inst:IsA("BasePart") then
				local lowered = string.lower(inst.Name or "")
				if lowered == "baseplate"
					or string.find(lowered, "spawn", 1, true) ~= nil
					or lowered == "spawn"
					or lowered == "spawnpad"
					or lowered == "spawnpoint"
					or string.find(lowered, "plate", 1, true) ~= nil then
					protected[#protected + 1] = inst
				end
			end
		end

		cache.entries = protected
		cache.lastRefresh = now
	end

	killAllState.isKillAllSpawnProtectedTarget = function(rootPart)
		if not rootPart or not isArsenal then
			return false
		end

		killAllState.refreshKillAllSpawnProtectionCache()
		local rootPos = rootPart.Position
		for _, inst in ipairs(killAllState.spawnProtectionCache.entries) do
			if inst and inst.Parent and inst:IsA("BasePart") then
				local nameLower = string.lower(inst.Name or "")
				local radius = 0
				if inst:IsA("SpawnLocation") or string.find(nameLower, "spawn", 1, true) ~= nil then
					radius = 48
				elseif nameLower == "baseplate" or string.find(nameLower, "plate", 1, true) ~= nil then
					radius = 60
				end

				if radius > 0 then
					local delta = rootPos - inst.Position
					if delta.Magnitude <= radius then
						return true
					end
				end
			end
		end

		return false
	end

	killAllState.primeKillAllTarget = function(targetPlayer)
		if not killAllState.enabled or not targetPlayer or targetPlayer == player then
			return
		end

		task.spawn(function()
			local character = targetPlayer.Character or targetPlayer.CharacterAdded:Wait()
			if not killAllState.enabled or not character then
				return
			end

			local root = character:WaitForChild("HumanoidRootPart", 5)
			local head = character:WaitForChild("Head", 5)
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if not killAllState.enabled or not root or not head or not humanoid then
				return
			end

		if not killAllState.isKillAllTargetPlayer(targetPlayer) then
				return
			end

			killAllState.targetPlayer = targetPlayer
			killAllState.lastAcquire = 0
			killAllState.lastAttack = 0
		end)
	end

	killAllState.clearKillAllSpawnTracking = function()
		for _, conn in ipairs(killAllState.spawnConnections) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		killAllState.spawnConnections = {}
	end

	killAllState.startKillAllSpawnTracking = function()
		if #killAllState.spawnConnections > 0 then
			return
		end

		for _, targetPlayer in ipairs(Players:GetPlayers()) do
			if targetPlayer ~= player then
				killAllState.spawnConnections[#killAllState.spawnConnections + 1] = targetPlayer.CharacterAdded:Connect(function()
					killAllState.primeKillAllTarget(targetPlayer)
				end)
			end
		end

		killAllState.spawnConnections[#killAllState.spawnConnections + 1] = Players.PlayerAdded:Connect(function(targetPlayer)
			if targetPlayer == player then
				return
			end
			killAllState.spawnConnections[#killAllState.spawnConnections + 1] = targetPlayer.CharacterAdded:Connect(function()
				killAllState.primeKillAllTarget(targetPlayer)
			end)
		end)
	end



	-- =============== FIRE RATE SYSTEM LOGIC ===============
	-- Implementation notes:
	-- - Override weapon timing values through known descriptors.
	-- - Keep original values to support clean restore on disable.
	-- - Heartbeat loop should stay lightweight; avoid heavy per-frame allocations.

	FIRE_RATE_NAMES = {
		FireRate = true, BFireRate = true, Cooldown = true, Rate = true,
		ShootCooldown = true, FireCooldown = true, ShotDelay = true,
		Delay = true, AttackCooldown = true, BurstDelay = true, WindupTime = true,
		SemiDelay = true, TapDelay = true, TriggerDelay = true,
	}

	FIRE_RATE_RELOAD_NAMES = {
		ReloadTime = true, ReloadDuration = true, ReloadDelay = true,
		EquipTime = true, DeployTime = true,
	}

	FIRE_RATE_PROJECTILE_SPEED_NAMES = {
		ProjectileSpeed = true, BulletSpeed = true, MuzzleVelocity = true,
		Velocity = true, LaunchSpeed = true, ThrowSpeed = true,
	}

	applyFireRateOverride = function(desc)
		if not desc then return end
		if not (desc:IsA("NumberValue") or desc:IsA("IntValue")) then return end

		local name = desc.Name
		if not (FIRE_RATE_NAMES[name] or FIRE_RATE_RELOAD_NAMES[name] or FIRE_RATE_PROJECTILE_SPEED_NAMES[name]) then
			return
		end

		if fireRateState.originalWeaponValues[desc] == nil then
			fireRateState.originalWeaponValues[desc] = desc.Value
		end

		if FIRE_RATE_NAMES[name] then
			desc.Value = 0.001
		elseif FIRE_RATE_RELOAD_NAMES[name] then
			desc.Value = 0.05
		elseif FIRE_RATE_PROJECTILE_SPEED_NAMES[name] then
			desc.Value = math.max(desc.Value, 9000)
		end
	end

	applyFireRateOverrides = function()
		local function scanAndOverride(root)
			for _, desc in ipairs(root:GetDescendants()) do
				applyFireRateOverride(desc)
			end
		end

		local weaponsFolder = ReplicatedStorage:FindFirstChild("Weapons")
		if weaponsFolder then scanAndOverride(weaponsFolder) end

		local char = player.Character
		if char then
			local tool = char:FindFirstChildOfClass("Tool")
			if tool then scanAndOverride(tool) end
			local backpack = player:FindFirstChildOfClass("Backpack")
			if backpack then scanAndOverride(backpack) end
		end
	end

	function connectFireRateOverrideRoot(root)
		if not root then return end
		if not root:IsA("Instance") then return end

		fireRateState.overrideConnections[#fireRateState.overrideConnections + 1] = root.DescendantAdded:Connect(function(desc)
			if fireRateState.enabled then
				applyFireRateOverride(desc)
			end
		end)
	end

	function disconnectFireRateOverrideRoots()
		for _, conn in ipairs(fireRateState.overrideConnections) do
			pcall(function() conn:Disconnect() end)
		end
		fireRateState.overrideConnections = {}
	end

	function restoreOriginalFireRates()
		for desc, origValue in pairs(fireRateState.originalWeaponValues) do
			pcall(function()
				desc.Value = origValue
			end)
		end
		fireRateState.originalWeaponValues = {}
	end

	function isGunTool(tool)
		if not tool or not tool:IsA("Tool") then return false end
		local nameLower = tool.Name:lower()
		local keywords = {"gun","rifle","pistol","shotgun","sniper","ar","smg","ak","m4","mp5","ump","glock","blaster","laser","cannon"}
		for _, kw in ipairs(keywords) do
			if nameLower:find(kw) then return true end
		end
		-- Deep check for remotes/animations
		for _, v in ipairs(tool:GetDescendants()) do
			if v:IsA("RemoteEvent") or v.Name:lower():find("fire") or v.Name:lower():find("shoot") or v:IsA("Animation") then
				return true
			end
		end
		return false
	end

	updateGunIndicator = function()
		local camera = workspace.CurrentCamera
		local viewportSize = camera and camera.ViewportSize or Vector2.new(0, 0)
		local center = Vector2.new(viewportSize.X / 2, viewportSize.Y / 2)
		if aimDraw.gunIndicator then
			aimDraw.gunIndicator.Position = center
			aimDraw.gunIndicator.Visible = fireRateState.enabled and fireRateState.currentTool and isGunTool(fireRateState.currentTool) or false
		end
	end

	function onToolEquipped(tool)
		fireRateState.currentTool = tool
		updateGunIndicator()

		if isGunTool(tool) then
			applyAdvancedWeaponMods(tool)
		end
	end

	function onToolUnequipped()
		fireRateState.currentTool = nil
		updateGunIndicator()
	end

	function fireToolBurst(tool, targetHead)
		if not tool then return end
		local targetPos = targetHead and targetHead.Position
		local cam = workspace.CurrentCamera
		local camCF = cam and cam.CFrame
		local nameLower = string.lower(tool.Name)
		local shotsThisTick = 1
		if nameLower:find("semi", 1, true)
			or nameLower:find("pistol", 1, true)
			or nameLower:find("revolver", 1, true)
			or nameLower:find("sniper", 1, true)
			or nameLower:find("shotgun", 1, true)
			or nameLower:find("crossbow", 1, true)
			or nameLower:find("launcher", 1, true)
			or nameLower:find("rpg", 1, true)
			or nameLower:find("rocket", 1, true)
			or nameLower:find("missile", 1, true)
			or nameLower:find("bazooka", 1, true)
			or nameLower:find("grenade", 1, true)
			or nameLower:find("ordnance", 1, true)
		then
			shotsThisTick = 2
		end

		for _ = 1, shotsThisTick do
			pcall(function() tool:Activate() end)
		end
		local virtualInputManager = nil
		pcall(function()
			virtualInputManager = game:GetService("VirtualInputManager")
		end)
		if virtualInputManager and cam then
			local centerX = math.floor(cam.ViewportSize.X * 0.5)
			local centerY = math.floor(cam.ViewportSize.Y * 0.5)
			pcall(function()
				virtualInputManager:SendMouseButtonEvent(centerX, centerY, 0, true, game, 0)
				virtualInputManager:SendMouseButtonEvent(centerX, centerY, 0, false, game, 0)
			end)
		end
		local virtualUser = nil
		pcall(function()
			virtualUser = game:GetService("VirtualUser")
		end)
		if virtualUser and cam then
			local center = Vector2.new(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5)
			pcall(function()
				virtualUser:Button1Down(center)
				virtualUser:Button1Up(center)
			end)
		end

		-- Fallback: fire all relevant remotes/bindables in the tool
		for _, v in ipairs(tool:GetDescendants()) do
			if v:IsA("RemoteEvent") then
				pcall(function() v:FireServer() end)
				if targetPos then
					pcall(function() v:FireServer(targetPos) end)
					pcall(function() v:FireServer(CFrame.new(targetPos), targetPos) end)
					if camCF then
						pcall(function() v:FireServer(camCF, targetPos, camCF.LookVector) end)
					end
				end
			elseif v:IsA("RemoteFunction") then
				pcall(function() v:InvokeServer() end)
				if targetPos then
					pcall(function() v:InvokeServer(targetPos) end)
					pcall(function() v:InvokeServer(CFrame.new(targetPos), targetPos) end)
				end
			elseif v:IsA("BindableEvent") then
				pcall(function() v:Fire() end)
				if targetPos then
					pcall(function() v:Fire(targetPos) end)
				end
			elseif v:IsA("BindableFunction") then
				pcall(function() v:Invoke() end)
				if targetPos then
					pcall(function() v:Invoke(targetPos) end)
				end
			end
		end
	end

	function shootFastLoop()
		if not fireRateState.enabled then return end
		if not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then return end

		local tool = player.Character and player.Character:FindFirstChildOfClass("Tool")
		if tool and tick() - fireRateState.lastShotTime >= fireRateState.shootRate then
			fireToolBurst(tool, getClosestHeadInFOV())
			fireRateState.lastShotTime = tick()
		end
	end

	enableFireRate = function()
		if fireRateState.shootConnection then return end
		
		applyFireRateOverrides()
		disconnectFireRateOverrideRoots()

		local weaponsFolder = ReplicatedStorage:FindFirstChild("Weapons")
		if weaponsFolder then
			connectFireRateOverrideRoot(weaponsFolder)
		end
		if player.Character then
			connectFireRateOverrideRoot(player.Character)
		end
		local backpack = player:FindFirstChildOfClass("Backpack")
		if backpack then
			connectFireRateOverrideRoot(backpack)
		end
		
		-- Setup tool detection once
		if not fireRateState.gunDetectConnection then
			fireRateState.gunDetectConnection = player.CharacterAdded:Connect(function(char)
				connectFireRateOverrideRoot(char)
				char.ChildAdded:Connect(function(child)
					if child:IsA("Tool") then onToolEquipped(child) end
				end)
				char.ChildRemoved:Connect(function(child)
					if child:IsA("Tool") then onToolUnequipped() end
				end)
				
				-- Check already equipped tool
				local existing = char:FindFirstChildOfClass("Tool")
				if existing then onToolEquipped(existing) end
			end)
			
			-- Initial check
			if player.Character then
				for _, child in ipairs(player.Character:GetChildren()) do
					if child:IsA("Tool") then onToolEquipped(child) end
				end
			end
		end
		
		-- Start the loop
		if not fireRateState.shootConnection then
			fireRateState.shootConnection = RunService.Heartbeat:Connect(shootFastLoop)
		end
	end

	disableFireRate = function()
		if fireRateState.shootConnection then
			fireRateState.shootConnection:Disconnect()
			fireRateState.shootConnection = nil
		end
		disconnectFireRateOverrideRoots()
		
		restoreOriginalFireRates()
		fireRateState.currentTool = nil
		if aimDraw.gunIndicator then
			aimDraw.gunIndicator.Visible = false
		end
	end

	setFireRateState = function(enabled)
		fireRateState.enabled = enabled
		setFireRateCheck(enabled)
		if enabled then
			enableFireRate()
		else
			disableFireRate()
		end
	end

	fireRateToggle.MouseButton1Click:Connect(function()
		setFireRateState(not fireRateState.enabled)
	end)

	alwaysAutoToggle.MouseButton1Click:Connect(function()
		alwaysAutoState.enabled = not alwaysAutoState.enabled
		setAlwaysAutoCheck(alwaysAutoState.enabled)
	end)

	player.CharacterAdded:Connect(function()
		if fireRateState.enabled then
			-- Re-apply overrides after respawn without resetting the toggle
			task.wait(1)
			if fireRateState.enabled then
				applyFireRateOverrides()
			end
		end
	end)

	-- =============== FLASH SPEED SYSTEM ===============

	enableFlash = function()
		local char = player.Character
		if not char then return end
		
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if not humanoid then return end
		humanoid.WalkSpeed = flashState.speed
		
		-- Continuously maintain flash speed on character respawn
		if flashState.connection then flashState.connection:Disconnect() end
		flashState.connection = humanoid.Changed:Connect(function(prop)
			if prop == "WalkSpeed" and flashState.enabled then
				local currentHumanoid = char:FindFirstChildOfClass("Humanoid")
				if currentHumanoid then
					currentHumanoid.WalkSpeed = flashState.speed
				end
			end
		end)
	end

	disableFlash = function()
		local char = player.Character
		if not char then return end
		
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = 16 -- Default Roblox walk speed
		end
		
		if flashState.connection then
			flashState.connection:Disconnect()
			flashState.connection = nil
		end
	end

	flashToggle.MouseButton1Click:Connect(function()
		flashState.enabled = not flashState.enabled
		setFlashCheck(flashState.enabled)
		if flashState.enabled then
			enableFlash()
		else
			disableFlash()
		end
	end)

	-- Re-enable flash on character respawn
	player.CharacterAdded:Connect(function(char)
		if flashState.enabled then
			task.wait(0.5) -- Wait for character to fully load
			enableFlash()
		end

		if longMeleeState.enabled then
			task.wait(0.5)
			toggleLongMelee(true)
		end
	end)

	-- =============== LONG MELEE EXTENSION ===============

	LONG_MELEE_VALUE_NAMES = {
		Range = true, MeleeRange = true, Reach = true, AttackRange = true,
		MaxDistance = true, HitDistance = true, ValidationRange = true,
		ServerRange = true, MaxRange = true, MaxAttackRange = true,
		HitRange = true, ValidationDistance = true, ServerDistance = true,
		MaxHitDistance = true, AttackDistance = true, SwingRange = true,
		DistanceLimit = true, RangeLimit = true, StabRange = true,
		SlashRange = true, CombatRange = true, StrikeRange = true,
		WeaponRange = true, DamageRange = true, EffectiveRange = true,
		InteractionRange = true, ActionRange = true, MaxReach = true,
		AttackReach = true, MeleeReach = true, HitReach = true,
		CombatDistance = true, StrikeDistance = true, WeaponDistance = true,
		ProjectileRange = true, BulletRange = true, FireRange = true,
		ExplosionRange = true, BlastRange = true, ImpactRange = true,
		ChainRange = true, LinkRange = true, ConnectionRange = true,
	}

	LONG_MELEE_ATTRIBUTE_NAMES = {
		Range = true, MeleeRange = true, Reach = true, AttackRange = true,
		MaxDistance = true, HitDistance = true, ValidationRange = true,
		MaxRange = true, CombatRange = true, StrikeRange = true,
		AttackDistance = true, CombatDistance = true, StrikeDistance = true,
		MeleeDistance = true, KnifeRange = true, SlashRange = true, StabRange = true,
	}

	LONG_MELEE_RANGED_KEYWORDS = {
		"gun", "rifle", "pistol", "shotgun", "sniper", "smg", "launcher", "rocket",
		"grenade", "bow", "crossbow", "projectile", "bullet", "blaster", "laser",
	}

	local LONG_MELEE_TARGET_VALUE = 1000000

	isRangedLikeObject = function(inst)
		if not inst then return false end
		local lowered = string.lower(inst.Name or "")
		for _, keyword in ipairs(LONG_MELEE_RANGED_KEYWORDS) do
			if string.find(lowered, keyword, 1, true) ~= nil then
				return true
			end
		end
		return false
	end

	isMeleeLikeObject = function(inst)
		if not inst then return false end
		local lowered = string.lower(inst.Name or "")
		if isRangedLikeObject(inst) then
			return false
		end
		return string.find(lowered, "melee", 1, true) ~= nil
			or string.find(lowered, "knife", 1, true) ~= nil
			or string.find(lowered, "sword", 1, true) ~= nil
			or string.find(lowered, "blade", 1, true) ~= nil
			or string.find(lowered, "katana", 1, true) ~= nil
			or string.find(lowered, "machete", 1, true) ~= nil
			or string.find(lowered, "bat", 1, true) ~= nil
			or string.find(lowered, "hammer", 1, true) ~= nil
			or string.find(lowered, "fist", 1, true) ~= nil
			or string.find(lowered, "axe", 1, true) ~= nil
			or string.find(lowered, "spear", 1, true) ~= nil
			or string.find(lowered, "dagger", 1, true) ~= nil
			or string.find(lowered, "crowbar", 1, true) ~= nil
			or string.find(lowered, "club", 1, true) ~= nil
			or string.find(lowered, "shovel", 1, true) ~= nil
			or string.find(lowered, "pickaxe", 1, true) ~= nil
			or string.find(lowered, "wrench", 1, true) ~= nil
			or string.find(lowered, "scythe", 1, true) ~= nil
			or string.find(lowered, "lance", 1, true) ~= nil
			or string.find(lowered, "halberd", 1, true) ~= nil
			or string.find(lowered, "staff", 1, true) ~= nil
			or string.find(lowered, "cane", 1, true) ~= nil
			or string.find(lowered, "stick", 1, true) ~= nil
			or string.find(lowered, "pipe", 1, true) ~= nil
			or string.find(lowered, "bottle", 1, true) ~= nil
	end

	isLikelyMeleeContext = function(inst)
		if not inst then return false end
		local cursor = inst
		for _ = 1, 6 do
			if not cursor then
				break
			end
			if isMeleeLikeObject(cursor) then
				return true
			end
			if isRangedLikeObject(cursor) then
				return false
			end
			if cursor:IsA("Tool") then
				local weaponType = cursor:GetAttribute("WeaponType")
				if type(weaponType) == "string" then
					local loweredType = string.lower(weaponType)
					if string.find(loweredType, "melee", 1, true) ~= nil then
						return true
					end
					if string.find(loweredType, "gun", 1, true) ~= nil
						or string.find(loweredType, "ranged", 1, true) ~= nil then
						return false
					end
				end
				if cursor:GetAttribute("IsMelee") == true or cursor:GetAttribute("Melee") == true then
					return true
				end
			end
			cursor = cursor.Parent
		end
		return false
	end

	setLongMeleeValue = function(desc)
		if not desc or not LONG_MELEE_VALUE_NAMES[desc.Name] then return end
		if not (desc:IsA("NumberValue") or desc:IsA("IntValue") or desc:IsA("Vector3Value")) then return end

		if longMeleeState.originalValues[desc] == nil then
			longMeleeState.originalValues[desc] = desc.Value
		end

		if desc:IsA("Vector3Value") then
			desc.Value = Vector3.new(LONG_MELEE_TARGET_VALUE, LONG_MELEE_TARGET_VALUE, LONG_MELEE_TARGET_VALUE)
		elseif desc:IsA("IntValue") then
			desc.Value = LONG_MELEE_TARGET_VALUE
		else
			desc.Value = LONG_MELEE_TARGET_VALUE
		end
	end

	setLongMeleeAttributes = function(inst)
		if not inst or not isLikelyMeleeContext(inst) then
			return
		end
		local attrs = inst:GetAttributes()
		for attrName, attrValue in pairs(attrs) do
			if LONG_MELEE_ATTRIBUTE_NAMES[attrName] and (type(attrValue) == "number") then
				local bucket = longMeleeState.originalAttributes[inst]
				if bucket == nil then
					bucket = {}
					longMeleeState.originalAttributes[inst] = bucket
				end
				if bucket[attrName] == nil then
					bucket[attrName] = attrValue
				end
				pcall(function()
					inst:SetAttribute(attrName, LONG_MELEE_TARGET_VALUE)
				end)
			end
		end
	end

	applyLongMeleeToRoot = function(root)
		if not root then return end
		setLongMeleeAttributes(root)
		for _, desc in ipairs(root:GetDescendants()) do
			setLongMeleeAttributes(desc)
			if LONG_MELEE_VALUE_NAMES[desc.Name] then
				local hasMeleeContext = isLikelyMeleeContext(desc)
				if hasMeleeContext then
					setLongMeleeValue(desc)
				end
			end
		end
	end

	clearLongMeleeConnections = function()
		for _, conn in ipairs(longMeleeState.connections) do
			pcall(function() conn:Disconnect() end)
		end
		longMeleeState.connections = {}
	end

	toggleLongMelee = function(state)
		local weaponsFolder = ReplicatedStorage:FindFirstChild("Weapons")
		clearLongMeleeConnections()
		
		if state then
			if weaponsFolder then
				applyLongMeleeToRoot(weaponsFolder)
				longMeleeState.connections[#longMeleeState.connections + 1] = weaponsFolder.DescendantAdded:Connect(function(desc)
					if longMeleeState.enabled then
						local hasMeleeContext = isLikelyMeleeContext(desc)
						if hasMeleeContext then
							setLongMeleeValue(desc)
						end
						setLongMeleeAttributes(desc)
					end
				end)
			end

			if player.Character then
				applyLongMeleeToRoot(player.Character)
				longMeleeState.connections[#longMeleeState.connections + 1] = player.Character.DescendantAdded:Connect(function(desc)
					if longMeleeState.enabled then
						local hasMeleeContext = isLikelyMeleeContext(desc)
						if hasMeleeContext then
							setLongMeleeValue(desc)
						end
						setLongMeleeAttributes(desc)
					end
				end)
			end

			local backpack = player:FindFirstChildOfClass("Backpack")
			if backpack then
				applyLongMeleeToRoot(backpack)
				longMeleeState.connections[#longMeleeState.connections + 1] = backpack.DescendantAdded:Connect(function(desc)
					if longMeleeState.enabled then
						local hasMeleeContext = isLikelyMeleeContext(desc)
						if hasMeleeContext then
							setLongMeleeValue(desc)
						end
						setLongMeleeAttributes(desc)
					end
				end)
			end
		else
			-- Restore original values
			for desc, origValue in pairs(longMeleeState.originalValues) do
				pcall(function() desc.Value = origValue end)
			end
			longMeleeState.originalValues = {}
			for inst, attrMap in pairs(longMeleeState.originalAttributes) do
				if inst and inst.Parent and type(attrMap) == "table" then
					for attrName, originalValue in pairs(attrMap) do
						pcall(function()
							inst:SetAttribute(attrName, originalValue)
						end)
					end
				end
			end
			longMeleeState.originalAttributes = {}
		end
	end

	longMeleeToggle.MouseButton1Click:Connect(function()
		longMeleeState.enabled = not longMeleeState.enabled
		setLongMeleeCheck(longMeleeState.enabled)
		toggleLongMelee(longMeleeState.enabled)
	end)

	brightNightToggle.MouseButton1Click:Connect(function()
		local parsedStrength = tonumber(brightNightStrengthInput.Text)
		if parsedStrength then
			worldBrightNightStrength = math.clamp(parsedStrength, 0.6, 2.4)
			brightNightStrengthInput.Text = string.format("%.2f", worldBrightNightStrength)
		else
			worldBrightNightStrength = worldFx.brightNightStrength or 1
			brightNightStrengthInput.Text = string.format("%.2f", worldBrightNightStrength)
		end
		worldFx.brightNightStrength = worldBrightNightStrength
		worldFx.brightNight = not worldFx.brightNight
		setBrightNightCheck(worldFx.brightNight)
		applyWorldFx()
	end)

	-- =============== NO RECOIL SYSTEM ===============
	-- Performance notes:
	-- - Track matching values once, then enforce in bounded chunks.
	-- - Use adaptive tick intervals to protect frame time on weaker devices.
	-- - Always unregister value/root hooks on disable to prevent leaks.

	function applyNoRecoilToRoot(root)
		if not root then return end
		local foundValues = 0
		if trackNoRecoilValue(root) then
			foundValues = foundValues + 1
		end
		for _, desc in ipairs(root:GetDescendants()) do
			if trackNoRecoilValue(desc) then
				foundValues = foundValues + 1
			end
		end
		registerNoRecoilRoot(root)
		if foundValues > 0 then
			logCommand("NO_RECOIL", true, string.format("Applied to %d values in %s", foundValues, root.Name), 0)
		end
	end

	function isNoRecoilValue(name)
		local lowered = string.lower(name)
		-- Primary recoil values
		if string.find(lowered, "recoil", 1, true)
			or string.find(lowered, "kick", 1, true)
			or string.find(lowered, "spread", 1, true)
			or string.find(lowered, "shake", 1, true)
			or string.find(lowered, "vibration", 1, true)
			or string.find(lowered, "bloom", 1, true)
			or string.find(lowered, "deviation", 1, true)
			or string.find(lowered, "inaccuracy", 1, true) then
			return true
		end

		-- Camera-related recoil (updated for newer Roblox versions)
		if string.find(lowered, "camera", 1, true) and (
			string.find(lowered, "recoil", 1, true) or
			string.find(lowered, "kick", 1, true) or
			string.find(lowered, "shake", 1, true) or
			string.find(lowered, "offset", 1, true) or
			string.find(lowered, "rotation", 1, true)
		) then
			return true
		end

		-- Gun/weapon specific recoil (updated patterns)
		if (string.find(lowered, "gun", 1, true) or string.find(lowered, "weapon", 1, true)) and (
			string.find(lowered, "recoil", 1, true) or
			string.find(lowered, "kick", 1, true) or
			string.find(lowered, "spread", 1, true) or
			string.find(lowered, "bloom", 1, true) or
			string.find(lowered, "deviation", 1, true)
		) then
			return true
		end

		-- Additional patterns for Roblox version 9d412f44a6fe4081
		if string.find(lowered, "stability", 1, true)
			or string.find(lowered, "accuracy", 1, true) and string.find(lowered, "penalty", 1, true)
			or string.find(lowered, "control", 1, true) and string.find(lowered, "loss", 1, true)
			or string.find(lowered, "feedback", 1, true)
			or string.find(lowered, "impulse", 1, true)
			or string.find(lowered, "force", 1, true) and string.find(lowered, "recoil", 1, true) then
			return true
		end

		return false
	end

	function isNoRecoilTypedValue(desc)
		return desc and (
			desc:IsA("NumberValue") or
			desc:IsA("IntValue") or
			desc:IsA("Vector3Value") or
			desc:IsA("BoolValue") or
			desc:IsA("CFrameValue")
		)
	end

	function forceNoRecoilValue(desc)
		if not desc or not desc.Parent or not isNoRecoilTypedValue(desc) then return false end
		if not noRecoilState.originalValues[desc] then
			noRecoilState.originalValues[desc] = desc.Value
		end

		if desc:IsA("Vector3Value") then
			desc.Value = Vector3.new(0, 0, 0)
		elseif desc:IsA("CFrameValue") then
			desc.Value = CFrame.new()
		elseif desc:IsA("BoolValue") then
			desc.Value = false
		else
			desc.Value = 0
		end
		return true
	end

	function untrackNoRecoilValue(desc)
		if not desc then return end
		if not noRecoilState.trackedLookup[desc] then return end
		noRecoilState.trackedLookup[desc] = nil

		local valueConn = noRecoilState.valueConnections[desc]
		if valueConn then
			valueConn:Disconnect()
			noRecoilState.valueConnections[desc] = nil
		end
	end

	function trackNoRecoilValue(desc)
		if not desc then return false end
		if not isNoRecoilTypedValue(desc) then return false end
		if not isNoRecoilValue(desc.Name) then return false end

		if not noRecoilState.trackedLookup[desc] then
			noRecoilState.trackedLookup[desc] = true
			table.insert(noRecoilState.trackedValues, desc)

			local valueConn = desc:GetPropertyChangedSignal("Value"):Connect(function()
				if noRecoilState.enabled then
					pcall(function()
						forceNoRecoilValue(desc)
					end)
				end
			end)
			noRecoilState.valueConnections[desc] = valueConn
		end

		if noRecoilState.enabled then
			pcall(function()
				forceNoRecoilValue(desc)
			end)
		end

		return true
	end

	function registerNoRecoilRoot(root)
		if not root or noRecoilState.rootConnections[root] then return end

		local addConn = root.DescendantAdded:Connect(function(desc)
			trackNoRecoilValue(desc)
		end)
		local removingConn = root.DescendantRemoving:Connect(function(desc)
			untrackNoRecoilValue(desc)
		end)

		noRecoilState.rootConnections[root] = {
			add = addConn,
			remove = removingConn,
		}
		table.insert(noRecoilState.rootConnectionList, root)
	end

	function clearNoRecoilTracking()
		for desc, conn in pairs(noRecoilState.valueConnections) do
			conn:Disconnect()
			noRecoilState.valueConnections[desc] = nil
		end

		for root, pack in pairs(noRecoilState.rootConnections) do
			if pack.add then pack.add:Disconnect() end
			if pack.remove then pack.remove:Disconnect() end
			noRecoilState.rootConnections[root] = nil
		end

		noRecoilState.rootConnectionList = {}
		noRecoilState.trackedValues = {}
		noRecoilState.trackedLookup = {}
		noRecoilState.applyCursor = 0
		noRecoilState.lastTickTime = 0
		noRecoilState.lastRescanTime = 0
	end

	function compactNoRecoilTrackedValues()
		local src = noRecoilState.trackedValues
		local dst = {}
		for _, desc in ipairs(src) do
			if desc and desc.Parent and noRecoilState.trackedLookup[desc] then
				dst[#dst + 1] = desc
			else
				if desc then
					untrackNoRecoilValue(desc)
				end
			end
		end
		noRecoilState.trackedValues = dst
		if #dst == 0 then
			noRecoilState.applyCursor = 0
		elseif noRecoilState.applyCursor > #dst then
			noRecoilState.applyCursor = 1
		end
	end

	function applyNoRecoilTick(dt)
		if not noRecoilState.enabled then return end

		local now = tick()
		if noRecoilState.lastTickTime > 0 and (now - noRecoilState.lastTickTime) < noRecoilState.applyInterval then
			return
		end
		noRecoilState.lastTickTime = now

		local trackedCount = #noRecoilState.trackedValues
		if trackedCount == 0 then return end

		if dt and dt > 0 then
			if noRecoilState.avgDt <= 0 then
				noRecoilState.avgDt = dt
			else
				noRecoilState.avgDt = (noRecoilState.avgDt * 0.9) + (dt * 0.1)
			end
		end

		local maxPerTick = noRecoilState.maxPerTick
		local baseInterval = noRecoilState.baseApplyInterval or 0.08
		if noRecoilState.avgDt > 0.03 then
			maxPerTick = math.max(70, math.floor(maxPerTick * 0.5))
			noRecoilState.applyInterval = math.max(baseInterval, 0.12)
		elseif noRecoilState.avgDt > 0.024 then
			maxPerTick = math.max(90, math.floor(maxPerTick * 0.7))
			noRecoilState.applyInterval = math.max(baseInterval, 0.1)
		else
			noRecoilState.applyInterval = baseInterval
		end

		local processed = 0
		while processed < maxPerTick and #noRecoilState.trackedValues > 0 do
			local idx = noRecoilState.applyCursor + 1
			if idx > #noRecoilState.trackedValues then
				idx = 1
			end
			noRecoilState.applyCursor = idx

			local desc = noRecoilState.trackedValues[idx]
			if desc and desc.Parent and noRecoilState.trackedLookup[desc] then
				pcall(function()
					forceNoRecoilValue(desc)
				end)
			else
				if desc then
					untrackNoRecoilValue(desc)
				end
				noRecoilState.trackedValues[idx] = noRecoilState.trackedValues[#noRecoilState.trackedValues]
				noRecoilState.trackedValues[#noRecoilState.trackedValues] = nil
				noRecoilState.applyCursor = idx - 1
				if noRecoilState.applyCursor < 0 then
					noRecoilState.applyCursor = 0
				end
			end
			processed = processed + 1
		end

		if (now - noRecoilState.lastRescanTime) > noRecoilState.rescanInterval then
			compactNoRecoilTrackedValues()
			noRecoilState.lastRescanTime = now
		end
	end

	killAllState.isValidKillAllPosition = function(position)
		if not position then
			return false
		end
		if position.X ~= position.X or position.Y ~= position.Y or position.Z ~= position.Z then
			return false
		end
		local minY = workspace.FallenPartsDestroyHeight + 20
		if position.Y <= minY then
			return false
		end
		return true
	end

	killAllState.isKillAllTargetPlayer = function(targetPlayer)
		if not targetPlayer or targetPlayer == player then
			return false
		end
		if isSameTeam(targetPlayer) then
			return false
		end
		local character = targetPlayer.Character
		if not character or not isCharacterAlive(character) then
			return false
		end
		if character:FindFirstChildOfClass("ForceField") then
			return false
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		local head = character:FindFirstChild("Head")
		if not root or not head then
			return false
		end
		if killAllState.isKillAllSpawnProtectedTarget(root) then
			return false
		end
		if not killAllState.isValidKillAllPosition(root.Position) then
			return false
		end
		return true
	end

	killAllState.getBestKillAllTarget = function(localRoot)
		local bestPlayer = nil
		local bestDistance = math.huge
		for _, targetPlayer in ipairs(Players:GetPlayers()) do
			if killAllState.isKillAllTargetPlayer(targetPlayer) then
				local enemyRoot = targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart")
				if enemyRoot then
					local distance = (localRoot.Position - enemyRoot.Position).Magnitude
					if distance < bestDistance then
						bestDistance = distance
						bestPlayer = targetPlayer
					end
				end
			end
		end
		return bestPlayer
	end

	killAllState.getKillAllTool = function(localCharacter, localHumanoid)
		if localCharacter then
			local equippedTool = localCharacter:FindFirstChildOfClass("Tool")
			if equippedTool then
				return equippedTool
			end
		end

		local backpack = player:FindFirstChildOfClass("Backpack")
		if backpack and localHumanoid then
			for _, child in ipairs(backpack:GetChildren()) do
				if child:IsA("Tool") then
					pcall(function()
						localHumanoid:EquipTool(child)
					end)
					return child
				end
			end
		end

		return nil
	end

	killAllState.stopKillAllController = function()
		if killAllState.connection then
			killAllState.connection:Disconnect()
			killAllState.connection = nil
		end
		killAllState.clearKillAllSpawnTracking()
		local localCharacter = player.Character
		local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
		local localHumanoid = localCharacter and localCharacter:FindFirstChildOfClass("Humanoid")
		if localRoot then
			localRoot.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			localRoot.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
		end
		if localHumanoid then
			localHumanoid.AutoRotate = true
		end
		killAllState.targetPlayer = nil
		killAllState.lastAcquire = 0
		killAllState.lastAttack = 0
		killAllState.lastHumanoid = nil
	end

	killAllState.ensureKillAllController = function()
		if killAllState.connection then
			return
		end
		killAllState.connection = RunService.RenderStepped:Connect(function()
			if not killAllState.enabled then
				return
			end

			local localCharacter = player.Character
			local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
			local localHumanoid = localCharacter and localCharacter:FindFirstChildOfClass("Humanoid")
			if not localRoot or not localHumanoid then
				killAllState.lastHumanoid = nil
				return
			end

			localHumanoid.AutoRotate = false
			killAllState.lastHumanoid = localHumanoid
			local targetTool = killAllState.getKillAllTool(localCharacter, localHumanoid)
			local meleeTool = killAllState.isKillAllMeleeTool(targetTool)

			local currentTarget = killAllState.targetPlayer
			local shouldAcquireNow = false
			if not killAllState.isKillAllTargetPlayer(currentTarget) then
				currentTarget = nil
				killAllState.targetPlayer = nil
				killAllState.lastAttack = 0
				shouldAcquireNow = true
			end

			local now = tick()
			if not currentTarget and (shouldAcquireNow or (now - killAllState.lastAcquire) >= killAllState.acquireInterval) then
				currentTarget = killAllState.getBestKillAllTarget(localRoot)
				killAllState.targetPlayer = currentTarget
				killAllState.lastAcquire = now
				if currentTarget then
					killAllState.orbitSide = -killAllState.orbitSide
				end
			end

			if not currentTarget then
				return
			end

			local targetCharacter = currentTarget.Character
			local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
			local targetHead = targetCharacter and targetCharacter:FindFirstChild("Head")
			if not targetRoot or not targetHead or not killAllState.isValidKillAllPosition(targetRoot.Position) then
				killAllState.targetPlayer = nil
				killAllState.lastAcquire = 0
				killAllState.lastAttack = 0
				return
			end

			local behindDistance = meleeTool and 1.9 or killAllState.behindDistance
			local heightOffset = meleeTool and 2.1 or killAllState.heightOffset
			local sideOffsetAmount = meleeTool and 0.7 or killAllState.sideOffset
			local behindOffset = targetRoot.CFrame.LookVector * behindDistance
			local sideOffset = targetRoot.CFrame.RightVector * (sideOffsetAmount * killAllState.orbitSide)
			local hoverOffset = Vector3.new(0, heightOffset, 0)
			local desiredPosition = targetRoot.Position - behindOffset + sideOffset + hoverOffset
			local lookPosition = targetHead.Position + Vector3.new(0, killAllState.cameraAimHeight, 0)

			localRoot.CFrame = CFrame.new(desiredPosition, lookPosition)
			localRoot.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			localRoot.AssemblyAngularVelocity = Vector3.new(0, 0, 0)

			if targetTool and (now - killAllState.lastAttack) >= (meleeTool and 0.12 or killAllState.attackInterval) then
				local distanceToTarget = (localRoot.Position - targetRoot.Position).Magnitude
				if not meleeTool or distanceToTarget <= 12 then
					fireToolBurst(targetTool, targetHead)
					killAllState.lastAttack = now
				end
			end

			local currentCamera = workspace.CurrentCamera
			if currentCamera then
				currentCamera.CFrame = CFrame.new(currentCamera.CFrame.Position, lookPosition)
			end
		end)
	end

	-- =============== FLY SYSTEM ===============
	flyState.resetInputState = function()
		flyState.isSpaceDown = false
		flyState.forward = false
		flyState.back = false
		flyState.left = false
		flyState.right = false
		flyState.up = false
		flyState.down = false
		flyState.boost = false
	end

	flyState.setKeyState = function(keyCode, isDown)
		if keyCode == Enum.KeyCode.W then
			flyState.forward = isDown
		elseif keyCode == Enum.KeyCode.S then
			flyState.back = isDown
		elseif keyCode == Enum.KeyCode.A then
			flyState.left = isDown
		elseif keyCode == Enum.KeyCode.D then
			flyState.right = isDown
		elseif keyCode == Enum.KeyCode.Space then
			flyState.up = isDown
			flyState.isSpaceDown = isDown
		elseif keyCode == Enum.KeyCode.LeftControl or keyCode == Enum.KeyCode.C then
			flyState.down = isDown
		elseif keyCode == Enum.KeyCode.LeftShift then
			flyState.boost = isDown
		end
	end

	flyState.stopController = function()
		if flyState.velocityConnection then
			flyState.velocityConnection:Disconnect()
			flyState.velocityConnection = nil
		end
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
		end
		if hum then
			hum.PlatformStand = false
			hum.AutoRotate = true
			pcall(function()
				hum:ChangeState(Enum.HumanoidStateType.GettingUp)
			end)
		end
		flyState.lastHumanoid = nil
		flyState.resetInputState()
	end

	flyState.ensureController = function()
		if flyState.velocityConnection then
			return
		end
		flyState.velocityConnection = RunService.RenderStepped:Connect(function()
			if not flyState.enabled then
				return
			end

			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if not hum or not root then
				return
			end

			if flyState.lastHumanoid ~= hum then
				flyState.lastHumanoid = hum
			end

			hum.PlatformStand = true
			hum.AutoRotate = false
			pcall(function()
				hum:ChangeState(Enum.HumanoidStateType.Physics)
			end)

			local cam = workspace.CurrentCamera
			local camCF = cam and cam.CFrame or root.CFrame
			local flatLook = Vector3.new(camCF.LookVector.X, 0, camCF.LookVector.Z)
			local flatRight = Vector3.new(camCF.RightVector.X, 0, camCF.RightVector.Z)
			if flatLook.Magnitude < 0.001 then flatLook = Vector3.new(0, 0, -1) else flatLook = flatLook.Unit end
			if flatRight.Magnitude < 0.001 then flatRight = Vector3.new(1, 0, 0) else flatRight = flatRight.Unit end

			local move = Vector3.new(0, 0, 0)
			if flyState.forward then move = move + flatLook end
			if flyState.back then move = move - flatLook end
			if flyState.right then move = move + flatRight end
			if flyState.left then move = move - flatRight end
			if flyState.up then move = move + Vector3.new(0, 1, 0) end
			if flyState.down then move = move - Vector3.new(0, 1, 0) end

			if move.Magnitude > 0 then
				move = move.Unit
			end

			local speed = flyState.speed
			if flyState.boost then
				speed = speed * flyState.boostMultiplier
			end
			root.AssemblyLinearVelocity = move * speed
			root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
		end)
	end

	flyToggle.MouseButton1Click:Connect(function()
		flyState.enabled = not flyState.enabled
		setFlyCheck(flyState.enabled)
		if flyState.enabled then
			if killAllState.enabled then
				killAllState.enabled = false
				setKillAllCheck(false)
				killAllState.stopKillAllController()
			end
			flyState.ensureController()
		else
			flyState.stopController()
		end
	end)

	killAllToggle.MouseButton1Click:Connect(function()
		killAllState.enabled = not killAllState.enabled
		setKillAllCheck(killAllState.enabled)
		if killAllState.enabled then
			if flyState.enabled then
				flyState.enabled = false
				setFlyCheck(false)
				flyState.stopController()
			end
			killAllState.startKillAllSpawnTracking()
			killAllState.ensureKillAllController()
		else
			killAllState.stopKillAllController()
		end
	end)

	-- =============== TAB SWITCH ROUTING ===============
	visualTab.MouseButton1Click:Connect(function()
		showMenuTab("visual")
	end)

	combatTab.MouseButton1Click:Connect(function()
		showMenuTab("combat")
	end)

	worldTab.MouseButton1Click:Connect(function()
		showMenuTab("world")
	end)

	settingsTab.MouseButton1Click:Connect(function()
		showMenuTab("settings")
	end)

	-- =============== HOTKEY ROUTER ===============
	glitchActive = true
	isMenuLoading = false

	UserInputService.InputBegan:Connect(function(input, gp)
		if gp then return end
		
		if flyState.enabled then
			flyState.setKeyState(input.KeyCode, true)
			flyState.ensureController()
		end
		
		if input.KeyCode == Enum.KeyCode.Insert then
			if isMenuLoading then
				return
			end
			setMenuVisible(not mainFrame.Visible)
			if menuAnimState.visibleTarget then
				showMenuTab(currentContentTab)
			end
		elseif input.KeyCode == Enum.KeyCode.F10 then
			mainFrame.GroupTransparency = mainFrame.GroupTransparency == 0 and 1 or 0
		elseif input.KeyCode == Enum.KeyCode.F1 then
			TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId) -- Rejoin
		elseif input.KeyCode == Enum.KeyCode.Delete or input.KeyCode == Enum.KeyCode.End then
			-- Full shutdown sequence: disable systems, restore state, then destroy UI.

			-- Rain cleanup
			if rainRenderConnection then
				rainRenderConnection:Disconnect()
				rainRenderConnection = nil
			end

			-- ESP cleanup
			espState.enabled = false
			setEspCheck(false)
			disableESP()

			-- Weapon chams cleanup
			chamsState.enabled = false
			setChamsCheck(false)
			disableChams()
			for obj, h in pairs(chamsHighlights) do
				pcall(function() h:Destroy() end)
			end
			chamsHighlights = {}

			rgbFills = {}
			rgbStrokes = {}

			-- Aimbot cleanup
			aimState.enabled = false
			setAimCheck(false)
			if aimDraw.fovCircle then
				aimDraw.fovCircle.Visible = false
			end
			if aimDraw.snapLine then
				aimDraw.snapLine.Visible = false
			end
			if aimDraw.gunIndicator then
				aimDraw.gunIndicator.Visible = false
			end

			-- Fire rate cleanup
			if fireRateState.gunDetectConnection then
				fireRateState.gunDetectConnection:Disconnect()
				fireRateState.gunDetectConnection = nil
			end
			fireRateState.enabled = false
			setFireRateCheck(false)
			disableFireRate()

			-- Flash speed cleanup
			flashState.enabled = false
			setFlashCheck(false)
			disableFlash()

			-- Long melee cleanup
			longMeleeState.enabled = false
			setLongMeleeCheck(false)
			toggleLongMelee(false)

			-- No recoil cleanup
			noRecoilState.enabled = false
			setNoRecoilCheck(false)
			toggleNoRecoil(false)

			-- World effects cleanup
			worldFx.brightNight = false
			setBrightNightCheck(false)
			applyWorldFx()

			-- Camera FOV cleanup
			if workspace.CurrentCamera and cameraFovState.default ~= nil then
				workspace.CurrentCamera.FieldOfView = cameraFovState.default
			end
			if cameraFovState.cameraSignal then
				cameraFovState.cameraSignal:Disconnect()
				cameraFovState.cameraSignal = nil
			end
			if cameraFovState.cameraSwapSignal then
				cameraFovState.cameraSwapSignal:Disconnect()
				cameraFovState.cameraSwapSignal = nil
			end
			cameraFovState.boundCamera = nil

			-- Custom sky cleanup
			worldFx.customSky = false
			setCustomSkyCheck(false)
			applyCustomSky()

			-- Fly cleanup
			flyState.enabled = false
			setFlyCheck(false)
			flyState.stopController()

			-- Kill All cleanup
			killAllState.enabled = false
			setKillAllCheck(false)
			killAllState.stopKillAllController()

			-- Stop render/color loops
			if visualConnection then
				visualConnection:Disconnect()
				visualConnection = nil
			end
			glitchActive = false

			-- Disconnect remaining render/update connections
			if widerFOVRenderConnection then
				if type(widerFOVRenderConnection) == "string" then
					pcall(function()
						RunService:UnbindFromRenderStep(widerFOVRenderConnection)
					end)
				else
					widerFOVRenderConnection:Disconnect()
				end
				widerFOVRenderConnection = nil
			end

			-- Remove Drawing API objects
			pcall(function() if aimDraw.fovCircle then aimDraw.fovCircle:Remove() end end)
			pcall(function() if aimDraw.crosshairH then aimDraw.crosshairH:Remove() end end)
			pcall(function() if aimDraw.crosshairV then aimDraw.crosshairV:Remove() end end)
			pcall(function() if aimDraw.crosshairHGlow then aimDraw.crosshairHGlow:Remove() end end)
			pcall(function() if aimDraw.crosshairVGlow then aimDraw.crosshairVGlow:Remove() end end)
			pcall(function() if aimDraw.snapLine then aimDraw.snapLine:Remove() end end)
			pcall(function() if aimDraw.gunIndicator then aimDraw.gunIndicator:Remove() end end)

			if renderUsernamesState.clearAll then
				renderUsernamesState.clearAll()
			end
			if renderUsernamesState.updateConnection then
				renderUsernamesState.updateConnection:Disconnect()
				renderUsernamesState.updateConnection = nil
			end
			renderUsernamesState.updateAccumulator = 0
			renderUsernamesState.scanCursor = 0
			renderUsernamesState.avatarCache = {}
			for trackedPlayer, connections in pairs(renderUsernamesState.connections) do
				for _, conn in ipairs(connections) do
					conn:Disconnect()
				end
				renderUsernamesState.connections[trackedPlayer] = nil
			end

			-- Unbind temporary input actions
			ContextActionService:UnbindAction(ACTION_BLOCK_BACKSPACE)
			ContextActionService:UnbindAction(ACTION_BLOCK_SPACE_WHEN_MENU_OPEN)

			-- Destroy main GUI last
			screenGui:Destroy()
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		flyState.setKeyState(input.KeyCode, false)
	end)

	-- =============== GLITCH BOOT EFFECT ===============
	task.spawn(function()
		while glitchActive do
			usernameLabel.Text = player.Name
			task.wait(1.8)
			
			for i = 1, 14 do
				local glitchStr = ""
				for char in player.Name:gmatch(".") do
					if math.random() < 0.45 then
						glitchStr = glitchStr .. string.char(math.random(33, 126))
					else
						glitchStr = glitchStr .. char
					end
				end
				usernameLabel.Text = glitchStr
				usernameLabel.Position = UDim2.new(0, 16 + math.random(-4,4), 0, math.random(-2,2))
				task.wait(0.03)
			end
		end
	end)

	function runMenuLoadingSequence()
		isMenuLoading = true
		mainFrame.Visible = false

		local loadingOverlay = Instance.new("Frame")
		loadingOverlay.Name = "MenuLoadingOverlay"
		loadingOverlay.Size = UDim2.new(1, 0, 1, 0)
		loadingOverlay.BackgroundColor3 = Color3.fromRGB(8, 8, 14)
		loadingOverlay.BackgroundTransparency = 0.1
		loadingOverlay.BorderSizePixel = 0
		loadingOverlay.ZIndex = 12000
		loadingOverlay.Parent = screenGui

		local flashOverlay = Instance.new("Frame")
		flashOverlay.Name = "MenuFlashOverlay"
		flashOverlay.Size = UDim2.new(1, 0, 1, 0)
		flashOverlay.BackgroundColor3 = Color3.fromRGB(255, 72, 108)
		flashOverlay.BackgroundTransparency = 1
		flashOverlay.BorderSizePixel = 0
		flashOverlay.ZIndex = 12010
		flashOverlay.Parent = loadingOverlay

		local loadingGradient = Instance.new("UIGradient")
		loadingGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(16, 16, 24)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 8, 14)),
		})
		loadingGradient.Rotation = 120
		loadingGradient.Parent = loadingOverlay

		local loadingCard = Instance.new("Frame")
		loadingCard.Size = UDim2.new(0, 390, 0, 148)
		loadingCard.AnchorPoint = Vector2.new(0.5, 0.5)
		loadingCard.Position = UDim2.new(0.5, 0, 0.5, 0)
		loadingCard.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
		loadingCard.BorderSizePixel = 0
		loadingCard.ZIndex = 12001
		loadingCard.Parent = loadingOverlay

		local loadingCardScale = Instance.new("UIScale")
		loadingCardScale.Scale = 0.92
		loadingCardScale.Parent = loadingCard

		local loadingCardCorner = Instance.new("UICorner")
		loadingCardCorner.CornerRadius = UDim.new(0, 14)
		loadingCardCorner.Parent = loadingCard

		local loadingCardStroke = Instance.new("UIStroke")
		loadingCardStroke.Color = Color3.fromRGB(255, 40, 80)
		loadingCardStroke.Thickness = 1.8
		loadingCardStroke.Transparency = 0.08
		loadingCardStroke.Parent = loadingCard

		local scanline = Instance.new("Frame")
		scanline.Name = "Scanline"
		scanline.Size = UDim2.new(1, 0, 0, 2)
		scanline.Position = UDim2.new(0, 0, 0, 0)
		scanline.BackgroundColor3 = Color3.fromRGB(255, 96, 128)
		scanline.BackgroundTransparency = 0.45
		scanline.BorderSizePixel = 0
		scanline.ZIndex = 12003
		scanline.Parent = loadingCard

		local scanlineGradient = Instance.new("UIGradient")
		scanlineGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 76, 112)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 208, 220)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 76, 112)),
		})
		scanlineGradient.Parent = scanline

		local loadingTitle = Instance.new("TextLabel")
		loadingTitle.Size = UDim2.new(1, -24, 0, 28)
		loadingTitle.Position = UDim2.new(0, 12, 0, 10)
		loadingTitle.BackgroundTransparency = 1
		loadingTitle.Text = "NEUSENCE CONTROL SUITE"
		loadingTitle.TextColor3 = Color3.fromRGB(245, 240, 244)
		loadingTitle.TextSize = 18
		loadingTitle.Font = Enum.Font.GothamBold
		loadingTitle.TextXAlignment = Enum.TextXAlignment.Left
		loadingTitle.ZIndex = 12002
		loadingTitle.Parent = loadingCard

		local loadingTitleGhost = Instance.new("TextLabel")
		loadingTitleGhost.Size = loadingTitle.Size
		loadingTitleGhost.Position = loadingTitle.Position + UDim2.new(0, 2, 0, 0)
		loadingTitleGhost.BackgroundTransparency = 1
		loadingTitleGhost.Text = loadingTitle.Text
		loadingTitleGhost.TextColor3 = Color3.fromRGB(255, 84, 120)
		loadingTitleGhost.TextTransparency = 0.75
		loadingTitleGhost.TextSize = loadingTitle.TextSize
		loadingTitleGhost.Font = loadingTitle.Font
		loadingTitleGhost.TextXAlignment = Enum.TextXAlignment.Left
		loadingTitleGhost.ZIndex = 12001
		loadingTitleGhost.Parent = loadingCard

		local loadingStatus = Instance.new("TextLabel")
		loadingStatus.Size = UDim2.new(1, -24, 0, 18)
		loadingStatus.Position = UDim2.new(0, 12, 0, 42)
		loadingStatus.BackgroundTransparency = 1
		loadingStatus.Text = "Booting systems..."
		loadingStatus.TextColor3 = Color3.fromRGB(208, 168, 180)
		loadingStatus.TextSize = 13
		loadingStatus.Font = Enum.Font.Gotham
		loadingStatus.TextXAlignment = Enum.TextXAlignment.Left
		loadingStatus.ZIndex = 12002
		loadingStatus.Parent = loadingCard

		local loadingBarBg = Instance.new("Frame")
		loadingBarBg.Size = UDim2.new(1, -24, 0, 16)
		loadingBarBg.Position = UDim2.new(0, 12, 1, -34)
		loadingBarBg.BackgroundColor3 = Color3.fromRGB(16, 16, 22)
		loadingBarBg.BorderSizePixel = 0
		loadingBarBg.ZIndex = 12002
		loadingBarBg.Parent = loadingCard

		local loadingBarBgCorner = Instance.new("UICorner")
		loadingBarBgCorner.CornerRadius = UDim.new(0, 8)
		loadingBarBgCorner.Parent = loadingBarBg

		local loadingBarFill = Instance.new("Frame")
		loadingBarFill.Size = UDim2.new(0, 0, 1, 0)
		loadingBarFill.Position = UDim2.new(0, 0, 0, 0)
		loadingBarFill.BackgroundColor3 = Color3.fromRGB(255, 58, 96)
		loadingBarFill.BorderSizePixel = 0
		loadingBarFill.ZIndex = 12003
		loadingBarFill.Parent = loadingBarBg

		local loadingBarFillCorner = Instance.new("UICorner")
		loadingBarFillCorner.CornerRadius = UDim.new(0, 8)
		loadingBarFillCorner.Parent = loadingBarFill

		local loadingBarFillGradient = Instance.new("UIGradient")
		loadingBarFillGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 40, 80)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 120, 146)),
		})
		loadingBarFillGradient.Rotation = 0
		loadingBarFillGradient.Parent = loadingBarFill

		local loadingPct = Instance.new("TextLabel")
		loadingPct.Size = UDim2.new(0, 52, 0, 18)
		loadingPct.Position = UDim2.new(1, -58, 0, 12)
		loadingPct.BackgroundTransparency = 1
		loadingPct.Text = "0%"
		loadingPct.TextColor3 = Color3.fromRGB(255, 186, 198)
		loadingPct.TextSize = 14
		loadingPct.Font = Enum.Font.GothamBold
		loadingPct.TextXAlignment = Enum.TextXAlignment.Right
		loadingPct.ZIndex = 12002
		loadingPct.Parent = loadingCard

		loadingCard.BackgroundTransparency = 1
		loadingTitle.TextTransparency = 1
		loadingStatus.TextTransparency = 1
		loadingPct.TextTransparency = 1
		loadingBarBg.BackgroundTransparency = 1
		loadingBarFill.BackgroundTransparency = 1

		TweenService:Create(
			flashOverlay,
			TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{BackgroundTransparency = 0.55}
		):Play()
		task.wait(0.06)
		TweenService:Create(
			flashOverlay,
			TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{BackgroundTransparency = 1}
		):Play()

		TweenService:Create(
			loadingCard,
			TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{BackgroundTransparency = 0}
		):Play()
		TweenService:Create(
			loadingCardScale,
			TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{Scale = 1}
		):Play()
		TweenService:Create(
			loadingTitle,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{TextTransparency = 0}
		):Play()
		TweenService:Create(
			loadingStatus,
			TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{TextTransparency = 0}
		):Play()
		TweenService:Create(
			loadingPct,
			TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{TextTransparency = 0}
		):Play()
		TweenService:Create(
			loadingBarBg,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{BackgroundTransparency = 0}
		):Play()
		TweenService:Create(
			loadingBarFill,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{BackgroundTransparency = 0}
		):Play()

		local loadingFxActive = true
		task.spawn(function()
			while loadingFxActive and loadingOverlay.Parent do
				TweenService:Create(
					scanline,
					TweenInfo.new(0.35, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
					{Position = UDim2.new(0, 0, 1, -2)}
				):Play()
				task.wait(0.36)
				scanline.Position = UDim2.new(0, 0, 0, 0)
				loadingCardStroke.Thickness = 2.1
				task.wait(0.03)
				loadingCardStroke.Thickness = 1.5
			end
		end)

		task.spawn(function()
			while loadingFxActive and loadingOverlay.Parent do
				loadingTitleGhost.Visible = true
				loadingTitleGhost.Position = loadingTitle.Position + UDim2.new(0, math.random(-2, 2), 0, 0)
				task.wait(0.035)
				loadingTitleGhost.Visible = false
				task.wait(0.22)
			end
		end)

		local loadingSteps = {
			{pct = 0.2, status = "Initializing interface grid...", duration = 0.22},
			{pct = 0.45, status = "Binding combat modules...", duration = 0.24},
			{pct = 0.7, status = "Spinning render pipelines...", duration = 0.24},
			{pct = 0.9, status = "Calibrating visual overlays...", duration = 0.22},
			{pct = 1.0, status = "Ready.", duration = 0.18},
		}

		for _, step in ipairs(loadingSteps) do
			loadingStatus.Text = step.status
			loadingPct.Text = tostring(math.floor(step.pct * 100 + 0.5)) .. "%"
			TweenService:Create(
				loadingBarFill,
				TweenInfo.new(step.duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{Size = UDim2.new(step.pct, 0, 1, 0)}
			):Play()
			task.wait(step.duration)
		end

		TweenService:Create(
			loadingOverlay,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{BackgroundTransparency = 1}
		):Play()
		TweenService:Create(
			loadingCard,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{BackgroundTransparency = 1}
		):Play()
		task.wait(0.22)

		loadingOverlay:Destroy()

		mainFrame.Visible = true
		showMenuTab(currentContentTab)
		isMenuLoading = false
	end

	task.spawn(runMenuLoadingSequence)

	-- =============== DIAGNOSTIC EXPORT FUNCTIONS ===============
	-- Global functions to access logs (can be called from console)
	_G.getErrorReport = getErrorReport
	_G.getCommandReport = getCommandReport
	_G.clearErrorLog = function() errorLog = {} print("Error log cleared") end
	_G.clearCommandLog = function() commandLog = {} print("Command log cleared") end

	-- Display logs in chat (for debugging)
	_G.showErrorReport = function()
		local report = getErrorReport()
		for line in report:gmatch("[^\r\n]+") do
			print(line)
		end
	end

	_G.showCommandReport = function()
		local report = getCommandReport()
		for line in report:gmatch("[^\r\n]+") do
			print(line)
		end
	end

	-- Scan for recoil values in the game
	_G.scanRecoilValues = function()
		local found = {}
		local player = Players.LocalPlayer
		local locations = {
			ReplicatedStorage:FindFirstChild("Weapons"),
			ArsenalData,
			player.Character,
			player:FindFirstChildOfClass("Backpack"),
			player.Character and player.Character:FindFirstChildOfClass("Tool")
		}

		for _, location in ipairs(locations) do
			if location then
				for _, desc in ipairs(location:GetDescendants()) do
					if isNoRecoilValue(desc.Name) and (
						desc:IsA("NumberValue") or
						desc:IsA("IntValue") or
						desc:IsA("Vector3Value") or
						desc:IsA("BoolValue") or
						desc:IsA("CFrameValue")
					) then
						table.insert(found, {
							name = desc.Name,
							value = desc.Value,
							type = desc.ClassName,
							path = desc:GetFullName()
						})
					end
				end
			end
		end

		print("=== RECOIL VALUES SCAN ===")
		if #found > 0 then
			for _, item in ipairs(found) do
				print(string.format("%s (%s): %s at %s", item.name, item.type, tostring(item.value), item.path))
			end
		else
			print("No recoil values found!")
		end
		return found
	end

	-- Force apply no recoil (for manual testing)
	_G.forceNoRecoil = function()
		if not noRecoilState.enabled then
			print("NO RECOIL is not enabled. Enable it first from the menu.")
			return
		end

		local player = Players.LocalPlayer
		local locations = {
			ReplicatedStorage:FindFirstChild("Weapons"),
			ArsenalData,
			player.Character,
			player:FindFirstChildOfClass("Backpack"),
			player.Character and player.Character:FindFirstChildOfClass("Tool")
		}

		local totalApplied = 0
		for _, location in ipairs(locations) do
			if location then
				for _, desc in ipairs(location:GetDescendants()) do
					if isNoRecoilValue(desc.Name) and (
						desc:IsA("NumberValue") or
						desc:IsA("IntValue") or
						desc:IsA("Vector3Value") or
						desc:IsA("BoolValue") or
						desc:IsA("CFrameValue")
					) then
						if desc:IsA("Vector3Value") or desc:IsA("CFrameValue") then
							if desc:IsA("CFrameValue") then
								desc.Value = CFrame.new()
							else
								desc.Value = Vector3.new(0, 0, 0)
							end
						elseif desc:IsA("BoolValue") then
							desc.Value = false
						else
							desc.Value = 0
						end
						totalApplied = totalApplied + 1
					end
				end
			end
		end

		print(string.format("Force applied no recoil to %d values", totalApplied))
		logCommand("NO_RECOIL", true, string.format("Force applied to %d values", totalApplied), 0)
	end

	-- =============== ANTI-CHEAT DETECTION NOTIFICATION ===============
	do
	function detectAntiCheat()
		local detected = {}
		local acSignatures = {
			{patterns = {"Adonis", "adonis"}, label = "Adonis Admin"},
			{patterns = {"Byfron", "byfron", "Hyperion", "hyperion"}, label = "Byfron/Hyperion"},
			{patterns = {"Vape", "vape"}, label = "Vape AC"},
			{patterns = {"KNIGHTLAB", "KnightLab", "knightlab"}, label = "KnightLab AC"},
			{patterns = {"Nexure", "nexure"}, label = "Nexure AC"},
			{patterns = {"CreativeAC", "CreativeAntiCheat"}, label = "Creative AC"},
			{patterns = {"ServerSecure", "ServerAntiExploit"}, label = "Server Secure"},
			{patterns = {"AntiExploit", "AntiCheat", "Anti_Exploit", "Anti_Cheat", "anti_cheat", "anticheat"}, label = "Generic Anti-Cheat"},
			{patterns = {"GameGuard", "gameguard"}, label = "GameGuard"},
			{patterns = {"Kohl", "kohl"}, label = "Kohl's Admin"},
			{patterns = {"HDAdmin", "HD Admin"}, label = "HD Admin"},
			{patterns = {"BasicAdmin", "Basic Admin"}, label = "Basic Admin"},
			{patterns = {"SimpleAdmin"}, label = "Simple Admin"},
			{patterns = {"Valkyrie", "valkyrie"}, label = "Valkyrie AC"},
		}
		local remoteACNames = {"ValidateClient", "Heartbeat_AC", "AC_Verify", "CheckIntegrity", "SecurityCheck", "AntiTamper"}
		local searchLocations = {
			game:GetService("ServerScriptService"),
			game:GetService("ServerStorage"),
			ReplicatedStorage,
			game:GetService("Workspace"),
			game:GetService("StarterPlayer"),
			game:GetService("StarterGui"),
		}
		for _, location in ipairs(searchLocations) do
			local ok, descendants = pcall(function() return location:GetDescendants() end)
			if ok and descendants then
				for _, obj in ipairs(descendants) do
					local objName = obj.Name
					for _, sig in ipairs(acSignatures) do
						if not detected[sig.label] then
							for _, pattern in ipairs(sig.patterns) do
								if string.find(objName, pattern, 1, true) then
									detected[sig.label] = true
									break
								end
							end
						end
					end
					if (obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction")) then
						for _, rName in ipairs(remoteACNames) do
							if string.find(objName, rName, 1, true) then
								detected["Remote AC (" .. obj.Name .. ")"] = true
							end
						end
					end
				end
			end
		end
		local results = {}
		for label in pairs(detected) do
			results[#results + 1] = label
		end
		table.sort(results)
		if #results == 0 then
			results[1] = "None Detected"
		end
		return results
	end

	task.spawn(function()
		task.wait(1.5)
		local acResults = detectAntiCheat()
		local acText = table.concat(acResults, ", ")

		local acGui = Instance.new("ScreenGui")
		acGui.Name = "ACDetectNotif"
		acGui.ResetOnSpawn = false
		acGui.DisplayOrder = 10001
		acGui.IgnoreGuiInset = true
		acGui.Parent = game:GetService("CoreGui")

		local notifFrame = Instance.new("Frame")
		notifFrame.Name = "NotifCard"
		notifFrame.AnchorPoint = Vector2.new(1, 1)
		notifFrame.Position = UDim2.new(1, 300, 1, -16)
		notifFrame.Size = UDim2.new(0, 280, 0, 62)
		notifFrame.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
		notifFrame.BackgroundTransparency = 0.06
		notifFrame.BorderSizePixel = 0
		notifFrame.Parent = acGui

		local notifCorner = Instance.new("UICorner")
		notifCorner.CornerRadius = UDim.new(0, 10)
		notifCorner.Parent = notifFrame

		local notifStroke = Instance.new("UIStroke")
		notifStroke.Color = Color3.fromRGB(255, 40, 80)
		notifStroke.Thickness = 1.4
		notifStroke.Transparency = 0.3
		notifStroke.Parent = notifFrame

		local notifGradient = Instance.new("UIGradient")
		notifGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(18, 18, 26)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 8, 14)),
		})
		notifGradient.Rotation = 130
		notifGradient.Parent = notifFrame

		local titleLabel = Instance.new("TextLabel")
		titleLabel.Size = UDim2.new(1, -16, 0, 20)
		titleLabel.Position = UDim2.new(0, 10, 0, 6)
		titleLabel.BackgroundTransparency = 1
		titleLabel.Text = "ANTI-CHEAT DETECTED"
		titleLabel.TextColor3 = Color3.fromRGB(255, 78, 112)
		titleLabel.TextSize = 12
		titleLabel.Font = Enum.Font.GothamBold
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.Parent = notifFrame

		local acLabel = Instance.new("TextLabel")
		acLabel.Size = UDim2.new(1, -16, 0, 28)
		acLabel.Position = UDim2.new(0, 10, 0, 26)
		acLabel.BackgroundTransparency = 1
		acLabel.Text = acText
		acLabel.TextColor3 = Color3.fromRGB(232, 222, 228)
		acLabel.TextSize = 13
		acLabel.Font = Enum.Font.GothamMedium
		acLabel.TextXAlignment = Enum.TextXAlignment.Left
		acLabel.TextTruncate = Enum.TextTruncate.AtEnd
		acLabel.Parent = notifFrame

		TweenService:Create(notifFrame, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(1, -16, 1, -16)
		}):Play()

		task.delay(8, function()
			if notifFrame and notifFrame.Parent then
				TweenService:Create(notifFrame, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					Position = UDim2.new(1, 300, 1, -16)
				}):Play()
				task.delay(0.35, function()
					if acGui and acGui.Parent then
						acGui:Destroy()
					end
				end)
			end
		end)
	end)
	end -- do (anti-cheat notification)


	print("GROK GANGSTA MENU LOADED â€” MAX POWER ENGAGED (FIXED)")
	print("Advanced error reporting enabled. Use _G.getErrorReport() or _G.getCommandReport() to access logs.")
