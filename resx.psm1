﻿#!/usr/bin/env pwsh
#region    Classes
enum DE {
  I3
  BspWM
  Sway
}

enum Platform {
  Windows
  Linux
  MacOS
  Unknown
}

# Main class
<#
.EXAMPLE
  # Create instance and run
  $r = [resx]::new()
  $r.ShowMenu()
.NOTES
  Cross-platform PowerShell module for managing screen resolutions.
  Works on Windows (using explorer.exe) and Linux (with supported Desktop Environments).
  Requires PowerShell 7+.
#>
class resx {
  # Static properties
  static [string] $LogDir = [resx]::GetPlatformLogDir()
  static [string] $LogFile = "$([resx]::LogDir)/resx.log"
  static [Platform] $CurrentPlatform = [resx]::DetectPlatform()

  # Hidden internal properties
  hidden [string[]] $DisconnectedDisplays = @()
  hidden [string[]] $ConnectedDisplays = @()
  hidden [string[]] $Displays = @()
  hidden [int] $DisplayCount = 0

  # Constructor
  resx() {
    $this.InitLogging()
    $this.Log("Script started on $([resx]::CurrentPlatform) platform")
    $this.DetectDisplays()
  }

  # Platform detection
  static [Platform] DetectPlatform() {
    if ((Get-Variable -Name IsWindows).Value -or $env:OS -eq "Windows_NT") {
      return [Platform]::Windows
    } elseif ((Get-Variable -Name IsLinux).Value) {
      return [Platform]::Linux
    } elseif ((Get-Variable -Name IsMacOS).Value) {
      return [Platform]::MacOS
    } else {
      return [Platform]::Unknown
    }
  }

  # Get platform-appropriate log directory
  static [string] GetPlatformLogDir() {
    $d = switch ([resx]::DetectPlatform()) {
      "Windows" {
        "$env:LOCALAPPDATA/resx"
      }
      "Linux" {
        "$env:HOME/.local/share/resx"
      }
      "MacOS" {
        "$env:HOME/Library/Application Support/resx"
      }
      default {
        "$env:TEMP/resx"
      }
    }
    return $d
  }

  # Initialize log directory
  hidden [void] InitLogging() {
    if (![IO.Directory]::exists([resx]::LogDir)) {
      New-Item -ItemType Directory -Path ([resx]::LogDir) -Force | Out-Null
    }
  }

  # Log a message with timestamp
  hidden [void] Log([string]$Message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp : $Message"
    Add-Content -Path ([resx]::LogFile) -Value $logEntry
  }

  # Detect connected and disconnected displays (auto-detects platform)
  hidden [void] DetectDisplays() {
    $this.DetectDisplays([resx]::CurrentPlatform)
  }

  # Detect connected and disconnected displays (explicit platform)
  hidden [void] DetectDisplays([Platform]$Platform) {
    try {
      switch ($Platform) {
        "Windows" {
          try {
            # Get all monitors from WMI
            $monitors = Get-CimInstance -ClassName Win32_DesktopMonitor -ea Stop
            $videoControllers = Get-CimInstance -ClassName Win32_VideoController -ea Stop

            $this.connectedDisplays = @()
            $this.disconnectedDisplays = @()

            foreach ($controller in $videoControllers) {
              if ($controller.Name -and $controller.Name -ne "Microsoft Basic Display Adapter") {
                if ($controller.Availability -eq 3) {
                  # Available/enabled
                  $this.connectedDisplays += $controller.Name
                } else {
                  $this.disconnectedDisplays += $controller.Name
                }
              }
            }

            # Fallback: Use Get-Display if available (Windows 10+)
            if ($this.connectedDisplays.Count -eq 0) {
              try {
                $this.displays = Get-Display -ea Stop
                $this.connectedDisplays = $this.displays | ForEach-Object { "Display$($_.Index)" }
              } catch {
                # Final fallback: assume at least one display
                $this.connectedDisplays = @("Primary")
              }
            }
            $this.Displays = $this.ConnectedDisplays + $this.DisconnectedDisplays
            $this.DisplayCount = $this.Displays.Count
          } catch {
            $this.Log("Windows display detection failed: $($_.Exception.Message)")
            # Fallback to single display assumption
            $this.ConnectedDisplays = @("Primary")
            $this.DisconnectedDisplays = @()
            $this.Displays = $this.ConnectedDisplays
            $this.DisplayCount = 1
          }
        }
        "Linux" {
          try {
            $xrandrOutput = & xrandr
            $this.DisconnectedDisplays = $xrandrOutput | Where-Object { $_ -match '\sdisconnected' } | ForEach-Object { ($_ -split '\s+')[0] }
            $this.ConnectedDisplays = $xrandrOutput | Where-Object { $_ -match '\sconnected' -and $_ -notmatch '\sdisconnected' } | ForEach-Object { ($_ -split '\s+')[0] }
            $this.Displays = $this.ConnectedDisplays + $this.DisconnectedDisplays
            $this.DisplayCount = $this.Displays.Count
          } catch {
            $this.Log("Linux display detection failed: $($_.Exception.Message)")
            throw "Failed to run xrandr. Is it installed?"
          }
        }
        "MacOS" {
          $this.Log("MacOS display detection not yet implemented")
          throw "MacOS platform not yet supported"
        }
        default {
          throw "Unsupported platform: $Platform"
        }
      }

      $this.Log("Detected $($this.DisplayCount) displays: $($this.Displays -join ' ')")
      $this.Log("Detected disconnected displays: $($this.DisconnectedDisplays -join ' ')")
    } catch {
      $this.Log("Error detecting displays: $($_.Exception.Message)")
      throw $_
    }
  }

  # Restart DE/Explorer (auto-detects platform)
  hidden [void] RestartDE() {
    $this.RestartDE([resx]::CurrentPlatform, "BspWM")
  }

  # Restart DE/Explorer (explicit platform)
  hidden [void] RestartDE([Platform]$Platform, [DE]$name) {
    switch ($Platform) {
      "Windows" {
        $this.Log("Restarting Windows Explorer")
        try {
          # Restart explorer.exe to refresh display settings
          Stop-Process -Name "explorer" -Force -ea SilentlyContinue
          Start-Sleep -Seconds 2
          Start-Process "explorer.exe"
        } catch {
          $this.Log("Failed to restart explorer: $($_.Exception.Message)")
        }
      }
      "Linux" {
        $this.Log("Restarting Linux DE: $name")
        switch ($name) {
          "I3" {
            try { i3-msg restart } catch { $this.Log("Failed to restart i3: $($_.Exception.Message)") }
            break
          }
          "BspWM" {
            try { bspc wm -r } catch { $this.Log("Failed to restart bspwm: $($_.Exception.Message)") }
            break
          }
          "Sway" {
            try { swaymsg exit } catch { $this.Log("Failed to restart sway: $($_.Exception.Message)") }
            break
          }
          default {
            $this.Log("Unknown or unsupported DE: $name")
          }
        }
      }
      default {
        $this.Log("DE restart not supported on $Platform")
      }
    }
  }

  # Turn off disconnected displays (auto-detects platform)
  hidden [void] TurnOffDisconnected() {
    $this.TurnOffDisconnected([resx]::CurrentPlatform)
  }

  # Turn off disconnected displays (explicit platform)
  hidden [void] TurnOffDisconnected([Platform]$Platform) {
    switch ($Platform) {
      "Windows" {
        # Windows handles disconnected displays automatically
        $this.Log("Windows automatically manages disconnected displays")
      }
      "Linux" {
        foreach ($disp in $this.DisconnectedDisplays) {
          $this.Log("Turning off disconnected display: $disp")
          try {
            xrandr --output $disp --off
          } catch {
            $this.Log("Failed to turn off display $disp : $($_.Exception.Message)")
          }
        }
      }
      default {
        $this.Log("Display management not supported on $Platform")
      }
    }
  }

  # Get available resolutions for a display (auto-detects platform)
  hidden [string[]] GetResolutions([string]$Display) {
    return $this.GetResolutions([resx]::CurrentPlatform, $Display)
  }

  # Get available resolutions for a display (explicit platform)
  hidden [string[]] GetResolutions([Platform]$Platform, [string] $Display) {
    $res = @()
    switch ($Platform) {
      "Windows" {
        try {
          # Get current display modes from WMI
          $videoModes = Get-CimInstance -ClassName Win32_VideoController |
            Where-Object { $_.Name -like "*$Display*" -or $Display -eq "Primary" } |
            Select-Object -First 1 |
            ForEach-Object { $_.VideoModeDescription }

          # Try to get available modes from registry or use common resolutions
          $commonResolutions = @(
            "3840x2160", "2560x1440", "1920x1080", "1680x1050",
            "1600x900", "1366x768", "1280x1024", "1280x720", "1024x768"
          )

          # Filter to reasonable resolutions (could be enhanced with actual hardware query)
          $res = $commonResolutions
        } catch {
          $this.Log("Failed to get Windows resolutions: $($_.Exception.Message)")
          $res = @("1920x1080", "1366x768", "1280x720")
        };
        break
      }
      "Linux" {
        try {
          $output = & xrandr --query
          $start = $false
          $modes = @()
          foreach ($line in $output) {
            if ($line -match "^$Display connected") { $start = $true; continue }
            if ($start -and $line -match '^\s') {
              if ($line -match '\d+x\d+') {
                $modes += [regex]::Matches($line, '\d+x\d+').Value
              }
            } elseif ($start -and $line -notmatch '^\s') {
              break
            }
          }
          $res = ($modes | Sort-Object -Unique)
        } catch {
          $this.Log("Failed to get Linux resolutions: $($_.Exception.Message)")
          $res = @("1920x1080", "1366x768", "1280x720")
        }
        break
      }
      default {
        $this.Log("Resolution detection not supported on $Platform")
        $res = @("1920x1080", "1366x768", "1280x720") # Common fallback resolutions
      }
    }
    return $res
  }

  # Create dynamic menu options
  hidden [string[]] CreateOptions() {
    $options = [System.Collections.Generic.List[string]]::new()

    if ($this.DisplayCount -gt 1) {
      $options.Add("Extend displays")
      $options.Add("Mirror displays")
      $options.Add("Custom layout")
    }

    foreach ($disp in $this.Displays) {
      $options.Add("Show only $disp")
    }

    foreach ($disp in $this.Displays) {
      $options.Add("Rotate $disp (normal/left/right/inverted)")
    }

    foreach ($disp in $this.Displays) {
      $options.Add("Set resolution for $disp")
    }

    return [string[]]$options
  }

  # Run command based on selected option (cross-platform)
  hidden [void] RunCmd([string] $Option) {
    $this.Log("Selected option: $Option")

    switch -Regex ($Option) {
      "Extend displays" {
        $this.ExtendDisplays()
      }

      "Mirror displays" {
        $this.MirrorDisplays()
      }

      "Show only (.*)" {
        $selectedDisplay = $matches[1]
        $this.ShowOnlyDisplay($selectedDisplay)
      }

      "Rotate (.*) \(.*\)" {
        $selectedDisplay = $matches[1]
        $this.RotateDisplay($selectedDisplay)
      }

      "Set resolution for (.*)" {
        $selectedDisplay = $matches[1]
        $this.SetDisplayResolution($selectedDisplay)
      }

      "Custom layout" {
        $this.CustomLayout()
      }

      default {
        $this.Log("Unknown option: $Option")
      }
    }

    # Finalize
    $this.TurnOffDisconnected()
    $this.RestartDE()
  }

  # Extend displays (auto-detects platform)
  hidden [void] ExtendDisplays() {
    $this.ExtendDisplays([resx]::CurrentPlatform)
  }

  # Extend displays (explicit platform)
  hidden [void] ExtendDisplays([Platform]$Platform) {
    switch ($Platform) {
      "Windows" {
        $this.Log("Extending displays on Windows")
        try {
          # Use DisplaySwitch.exe for extending displays
          Start-Process "DisplaySwitch.exe" -ArgumentList "/extend" -Wait -NoNewWindow
        } catch {
          $this.Log("Failed to extend displays: $($_.Exception.Message)")
        }
      }
      "Linux" {
        $primary = $this.Displays[0]
        $cmd = "xrandr --output `"$primary`" --auto --primary"
        $position = "right-of"
        for ($i = 1; $i -lt $this.DisplayCount; $i++) {
          $cmd += " --output `"$($this.Displays[$i])`" --auto --$position `"$primary`""
          $primary = $this.Displays[$i]
          $position = if ($position -eq "right-of") { "below" } else { "right-of" }
        }
        $this.Log("Running command: $cmd")
        try {
          Invoke-Expression $cmd
        } catch {
          $this.Log("Failed to extend displays: $($_.Exception.Message)")
        }
      }
      default {
        $this.Log("Extend displays not supported on $Platform")
      }
    }
  }

  # Mirror displays (auto-detects platform)
  hidden [void] MirrorDisplays() {
    $this.MirrorDisplays([resx]::CurrentPlatform)
  }

  # Mirror displays (explicit platform)
  hidden [void] MirrorDisplays([Platform]$Platform) {
    switch ($Platform) {
      "Windows" {
        $this.Log("Mirroring displays on Windows")
        try {
          # Use DisplaySwitch.exe for duplicating displays
          Start-Process "DisplaySwitch.exe" -ArgumentList "/clone" -Wait -NoNewWindow
        } catch {
          $this.Log("Failed to mirror displays: $($_.Exception.Message)")
        }
      }
      "Linux" {
        $primary = $this.Displays[0]
        $cmd = "xrandr --output `"$primary`" --auto --primary"
        for ($i = 1; $i -lt $this.DisplayCount; $i++) {
          $cmd += " --output `"$($this.Displays[$i])`" --auto --same-as `"$primary`""
        }
        $this.Log("Running command: $cmd")
        try {
          Invoke-Expression $cmd
        } catch {
          $this.Log("Failed to mirror displays: $($_.Exception.Message)")
        }
      }
      default {
        $this.Log("Mirror displays not supported on $Platform")
      }
    }
  }

  # Show only display (auto-detects platform)
  hidden [void] ShowOnlyDisplay([string] $selectedDisplay) {
    $this.ShowOnlyDisplay([resx]::CurrentPlatform, $selectedDisplay)
  }

  # Show only display (explicit platform)
  hidden [void] ShowOnlyDisplay([Platform]$Platform, [string] $selectedDisplay) {
    switch ($Platform) {
      "Windows" {
        $this.Log("Setting single display on Windows: $selectedDisplay")
        try {
          # Use DisplaySwitch.exe for internal display only
          Start-Process "DisplaySwitch.exe" -ArgumentList "/internal" -Wait -NoNewWindow
        } catch {
          $this.Log("Failed to set single display: $($_.Exception.Message)")
        }
      }
      "Linux" {
        $cmd = "xrandr --output `"$selectedDisplay`" --auto --primary"
        foreach ($disp in $this.Displays) {
          if ($disp -ne $selectedDisplay) {
            $cmd += " --output `"$disp`" --off"
          }
        }
        $this.Log("Running command: $cmd")
        try {
          Invoke-Expression $cmd
        } catch {
          $this.Log("Failed to set single display: $($_.Exception.Message)")
        }
      }
      default {
        $this.Log("Single display mode not supported on $Platform")
      }
    }
  }

  # Cross-platform rotate display
  hidden [void] RotateDisplay([string] $selectedDisplay) {
    $rotations = @("normal", "left", "right", "inverted")
    $rotation = $this.ShowSelectionMenu($rotations, "Select rotation for $selectedDisplay")

    if ($rotation) {
      switch ([resx]::CurrentPlatform) {
        "Windows" {
          $this.Log("Display rotation on Windows requires manual configuration through Display Settings")
          $this.Log("Opening Display Settings...")
          try {
            Start-Process "ms-settings:display"
          } catch {
            $this.Log("Failed to open Display Settings: $($_.Exception.Message)")
          }
        }
        "Linux" {
          $this.Log("Rotating $selectedDisplay to $rotation")
          try {
            xrandr --output $selectedDisplay --rotate $rotation
          } catch {
            $this.Log("Failed to rotate display: $($_.Exception.Message)")
          }
        }
        default {
          $this.Log("Display rotation not supported on $([resx]::CurrentPlatform)")
        }
      }
    }
  }

  # Cross-platform set display resolution
  hidden [void] SetDisplayResolution([string] $selectedDisplay) {
    $resolutions = $this.GetResolutions($selectedDisplay)
    $resolution = $this.ShowSelectionMenu($resolutions, "Select resolution for $selectedDisplay")

    if ($resolution) {
      switch ([resx]::CurrentPlatform) {
        "Windows" {
          $this.Log("Setting resolution on Windows requires manual configuration through Display Settings")
          $this.Log("Opening Display Settings...")
          try {
            Start-Process "ms-settings:display"
          } catch {
            $this.Log("Failed to open Display Settings: $($_.Exception.Message)")
          }
        }
        "Linux" {
          $this.Log("Setting resolution of $selectedDisplay to $resolution")
          try {
            # example: xrandr --output VGA1 --mode "1440x900_60.00"
            xrandr --output $selectedDisplay --mode $resolution
          } catch {
            $this.Log("Failed to set resolution: $($_.Exception.Message)")
          }
        }
        default {
          $this.Log("Resolution setting not supported on $([resx]::CurrentPlatform)")
        }
      }
    }
  }

  # Cross-platform custom layout
  hidden [void] CustomLayout() {
    $primary = $this.ShowSelectionMenu($this.Displays, "Select primary display")
    if (!$primary) { return }

    switch ([resx]::CurrentPlatform) {
      "Windows" {
        $this.Log("Custom layout on Windows requires manual configuration through Display Settings")
        $this.Log("Opening Display Settings...")
        try {
          Start-Process "ms-settings:display"
        } catch {
          $this.Log("Failed to open Display Settings: $($_.Exception.Message)")
        }
      }
      "Linux" {
        $cmd = "xrandr --output `"$primary`" --auto --primary"
        $this.Log("Selected primary display: $primary")

        foreach ($disp in $this.Displays) {
          if ($disp -eq $primary) { continue }
          $positions = @("right-of", "left-of", "above", "below", "same-as", "off")
          $position = $this.ShowSelectionMenu($positions, "Position for $disp relative to $primary")
          if ($position -eq "off") {
            $cmd += " --output `"$disp`" --off"
          } elseif ($position) {
            $cmd += " --output `"$disp`" --auto --$position `"$primary`""
          }
          $this.Log("Positioning $disp $position $primary")
        }
        $this.Log("Running command: $cmd")
        try {
          Invoke-Expression $cmd
        } catch {
          $this.Log("Failed to apply custom layout: $($_.Exception.Message)")
        }
      }
      default {
        $this.Log("Custom layout not supported on $([resx]::CurrentPlatform)")
      }
    }
  }

  # Selection menu (auto-detects platform)
  hidden [string] ShowSelectionMenu([string[]] $options, [string] $prompt) {
    return $this.ShowSelectionMenu([resx]::CurrentPlatform, $options, $prompt)
  }

  # Selection menu (explicit platform)
  hidden [string] ShowSelectionMenu([Platform]$Platform, [string[]] $options, [string] $prompt) {
    $selected = ''
    switch ($Platform) {
      "Windows" {
        # Use Out-GridView for Windows selection
        try {
          $selected = $options | Out-GridView -Title $prompt -OutputMode Single
        } catch {
          # Fallback to console selection
          Write-Host $prompt -ForegroundColor Cyan
          for ($i = 0; $i -lt $options.Count; $i++) {
            Write-Host "$($i + 1). $($options[$i])"
          }
          $choice = Read-Host "Enter selection number (1-$($options.Count))"
          if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $options.Count) {
            $selected = $options[[int]$choice - 1]
          }
        }
      }
      "Linux" {
        # Use rofi for Linux selection
        try {
          $optionStr = $options -join "`n"
          $selected = $optionStr | rofi -dmenu -p $prompt
        } catch {
          # Fallback to console selection
          Write-Host $prompt -ForegroundColor Cyan
          for ($i = 0; $i -lt $options.Count; $i++) {
            Write-Host "$($i + 1). $($options[$i])"
          }
          $choice = Read-Host "Enter selection number (1-$($options.Count))"
          if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $options.Count) {
            $selected = $options[[int]$choice - 1]
          }
        }
      }
      default {
        # Console fallback for other platforms
        Write-Host $prompt -ForegroundColor Cyan
        for ($i = 0; $i -lt $options.Count; $i++) {
          Write-Host "$($i + 1). $($options[$i])"
        }
        $choice = Read-Host "Enter selection number (1-$($options.Count))"
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $options.Count) {
          $selected = $options[[int]$choice - 1]
        }
      }
    }
    return $selected
  }

  # Main entry point (cross-platform)
  [void] ShowMenu() {
    if ($this.DisplayCount -eq 1) {
      $this.Log("Only one display detected: $($this.Displays[0])")
      switch ([resx]::CurrentPlatform) {
        "Windows" {
          $this.Log("Single display mode on Windows - no action needed")
        }
        "Linux" {
          try {
            xrandr --output $this.Displays[0] --auto --primary
          } catch {
            $this.Log("Failed to configure single display: $($_.Exception.Message)")
          }
        }
      }
      $this.TurnOffDisconnected()
      $this.RestartDE()
    } else {
      $options = $this.CreateOptions()
      $this.Log("Generated options:")
      $options | ForEach-Object { $this.Log(" - $_") }

      $chosen = $this.ShowSelectionMenu($options, "Display Settings - Select a display configuration")

      if ($chosen) {
        $this.RunCmd($chosen)
      } else {
        $this.Log("No option selected.")
      }
    }
    $this.Log("Script completed successfully")
  }

  # Optional: Generate modeline (Linux only - like cvt)
  [string] getModeline([int]$x, [int]$y, [int]$rate = 60) {
    if ([resx]::CurrentPlatform -ne "Linux") {
      $this.Log("Modeline generation only supported on Linux")
      return ""
    }

    try {
      $cvtOutput = cvt $x $y $rate
      return ($cvtOutput[1] -replace '^Modeline "\S+"\s+', '')
    } catch {
      $this.Log("Failed to generate modeline: $($_.Exception.Message)")
      return ""
    }
  }

  # Optional: Set resolution via newmode (Linux only - advanced)
  [void] setResolution([int]$x, [int]$y, [int]$rate = 60) {
    if ([resx]::CurrentPlatform -ne "Linux") {
      $this.Log("Custom resolution creation only supported on Linux")
      return
    }

    try {
      $modeline = $this.getModeline($x, $y, $rate)
      if ($modeline) {
        $modeName = "${x}x${y}_$rate"
        $this.Log("Creating new mode: $modeName")
        xrandr --newmode $modeName $modeline
        # You'd then add it to an output — depends on context
      }
    } catch {
      $this.Log("Failed to create custom resolution: $($_.Exception.Message)")
    }
  }
}

#endregion Classes
# Types that will be available to users when they import the module.
$typestoExport = @(
  [resx]
)
$TypeAcceleratorsClass = [PsObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
foreach ($Type in $typestoExport) {
  if ($Type.FullName -in $TypeAcceleratorsClass::Get.Keys) {
    $Message = @(
      "Unable to register type accelerator '$($Type.FullName)'"
      'Accelerator already exists.'
    ) -join ' - '
    "TypeAcceleratorAlreadyExists $Message" | Write-Debug
  }
}
# Add type accelerators for every exportable type.
foreach ($Type in $typestoExport) {
  $TypeAcceleratorsClass::Add($Type.FullName, $Type)
}
# Remove type accelerators when the module is removed.
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
  foreach ($Type in $typestoExport) {
    $TypeAcceleratorsClass::Remove($Type.FullName)
  }
}.GetNewClosure();

$scripts = @();
$Public = Get-ChildItem "$PSScriptRoot/Public" -Filter "*.ps1" -Recurse -ea SilentlyContinue
$scripts += Get-ChildItem "$PSScriptRoot/Private" -Filter "*.ps1" -Recurse -ea SilentlyContinue
$scripts += $Public

foreach ($file in $scripts) {
  try {
    if ([string]::IsNullOrWhiteSpace($file.fullname)) { continue }
    . "$($file.fullname)"
  } catch {
    Write-Warning "Failed to import function $($file.BaseName): $_"
    $host.UI.WriteErrorLine($_)
  }
}

$Param = @{
  Function = $Public.BaseName
  Cmdlet   = '*'
  Alias    = '*'
  Verbose  = $false
}
Export-ModuleMember @Param
