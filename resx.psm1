#!/usr/bin/env pwsh
#region    Classes
enum DE {
  I3
  BspWM
  Sway
}
# Main class
<#
.EXAMPLE
  # Create instance and run
  $r = [resx]::new()
  $r.ShowMenu()
.NOTES
  Assumption: You're running PowerShell on Linux (PowerShell 7+), and you have: xrandr, rofi, i3-msg
  already installed.
#>
class resx {
    # Static properties
    static [string] $LogDir = "$env:HOME/.local/share/resx"
    static [string] $LogFile = "$([resx]::LogDir)/resx.log"

    # Hidden internal properties
    hidden [string[]] $DisconnectedDisplays = @()
    hidden [string[]] $ConnectedDisplays = @()
    hidden [string[]] $Displays = @()
    hidden [int] $DisplayCount = 0

    # Constructor
    resx() {
        $this.InitLogging()
        $this.Log("Script started")
        $this.DetectDisplays()
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

    # Detect connected and disconnected displays
    hidden [void] DetectDisplays() {
        try {
            $xrandrOutput = & xrandr
            $this.DisconnectedDisplays = $xrandrOutput | Where-Object { $_ -match '\sdisconnected' } | ForEach-Object { ($_ -split '\s+')[0] }
            $this.ConnectedDisplays = $xrandrOutput | Where-Object { $_ -match '\sconnected' -and $_ -notmatch '\sdisconnected' } | ForEach-Object { ($_ -split '\s+')[0] }
            $this.Displays = $this.ConnectedDisplays
            $this.DisplayCount = $this.Displays.Count

            $this.Log("Detected $($this.DisplayCount) connected displays: $($this.Displays -join ' ')")
            $this.Log("Detected disconnected displays: $($this.DisconnectedDisplays -join ' ')")
        }
        catch {
            $this.Log("Error detecting displays: $($_.Exception.Message)")
            throw "Failed to run xrandr. Is it installed?"
        }
    }

    hidden [void] RestartDE() {
      $this.RestartDE("BspWM")
    }
    # Restart DE: EXAMPLE :i3, BSPWM, SWAY ...
    hidden [void] RestartDE([DE]$name) {
        $this.Log("Restarting i3")
        switch ($name) {
          "I3" { i3-msg restart; break }
          "BspWM" { bspc wm -r; break }
          "Sway" { swaymsg exit; break }
          Default {}
        }

    }

    # Turn off disconnected displays
    hidden [void] TurnOffDisconnected() {
        foreach ($disp in $this.DisconnectedDisplays) {
            $this.Log("Turning off disconnected display: $disp")
            xrandr --output $disp --off
        }
    }

    # Get available resolutions for a display
    hidden [string[]] GetResolutions([string] $Display) {
        $output = & xrandr --query
        $start = $false
        $modes = @()
        foreach ($line in $output) {
            if ($line -match "^$Display connected") { $start = $true; continue }
            if ($start -and $line -match '^\s') {
                if ($line -match '\d+x\d+') {
                    $modes += [regex]::Matches($line, '\d+x\d+').Value
                }
            }
            elseif ($start -and $line -notmatch '^\s') {
                break
            }
        }
        return ($modes | Sort-Object -Unique)
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

    # Run command based on selected option
    hidden [void] RunCmd([string] $Option) {
        $this.Log("Selected option: $Option")
        $cmd = ""

        switch -Regex ($Option) {
            "Extend displays" {
                $primary = $this.Displays[0]
                $cmd = "xrandr --output `"$primary`" --auto --primary"
                $position = "right-of"
                for ($i = 1; $i -lt $this.DisplayCount; $i++) {
                    $cmd += " --output `"$($this.Displays[$i])`" --auto --$position `"$primary`""
                    $primary = $this.Displays[$i]
                    $position = if ($position -eq "right-of") { "below" } else { "right-of" }
                }
                $this.Log("Running command: $cmd")
                Invoke-Expression $cmd
            }

            "Mirror displays" {
                $primary = $this.Displays[0]
                $cmd = "xrandr --output `"$primary`" --auto --primary"
                for ($i = 1; $i -lt $this.DisplayCount; $i++) {
                    $cmd += " --output `"$($this.Displays[$i])`" --auto --same-as `"$primary`""
                }
                $this.Log("Running command: $cmd")
                Invoke-Expression $cmd
            }

            "Show only (.*)" {
                $selectedDisplay = $matches[1]
                $cmd = "xrandr --output `"$selectedDisplay`" --auto --primary"
                foreach ($disp in $this.Displays) {
                    if ($disp -ne $selectedDisplay) {
                        $cmd += " --output `"$disp`" --off"
                    }
                }
                $this.Log("Running command: $cmd")
                Invoke-Expression $cmd
            }

            "Rotate (.*) \(.*\)" {
                $selectedDisplay = $matches[1]
                $rotation = @("normal", "left", "right", "inverted") | rofi -dmenu -p "Select rotation for $selectedDisplay"
                if ($rotation) {
                    $this.Log("Rotating $selectedDisplay to $rotation")
                    xrandr --output $selectedDisplay --rotate $rotation
                }
            }

            "Set resolution for (.*)" {
                $selectedDisplay = $matches[1]
                $resolutions = $this.GetResolutions($selectedDisplay) -join "`n"
                $resolution = $resolutions | rofi -dmenu -p "Select resolution for $selectedDisplay"
                if ($resolution) {
                    $this.Log("Setting resolution of $selectedDisplay to $resolution")
                    xrandr --output $selectedDisplay --mode $resolution
                }
            }

            "Custom layout" {
                $primary = $this.Displays -join "`n" | rofi -dmenu -p "Select primary display"
                if (!$primary) { return }

                $cmd = "xrandr --output `"$primary`" --auto --primary"
                $this.Log("Selected primary display: $primary")

                foreach ($disp in $this.Displays) {
                    if ($disp -eq $primary) { continue }
                    $positions = "right-of`nleft-of`nabove`nbelow`nsame-as`noff"
                    $position = $positions | rofi -dmenu -p "Position for $disp relative to $primary"
                    if ($position -eq "off") {
                        $cmd += " --output `"$disp`" --off"
                    }
                    elseif ($position) {
                        $cmd += " --output `"$disp`" --auto --$position `"$primary`""
                    }
                    $this.Log("Positioning $disp $position $primary")
                }
                $this.Log("Running command: $cmd")
                Invoke-Expression $cmd
            }

            default {
                $this.Log("Unknown option: $Option")
            }
        }

        # Finalize
        $this.TurnOffDisconnected()
        $this.RestartDE()
    }

    # Main entry point
    [void] ShowMenu() {
        if ($this.DisplayCount -eq 1) {
            $this.Log("Only one display detected: $($this.Displays[0])")
            xrandr --output $this.Displays[0] --auto --primary
            $this.TurnOffDisconnected()
            $this.RestartDE()
        }
        else {
            $options = $this.CreateOptions()
            $this.Log("Generated options:")
            $options | ForEach-Object { $this.Log(" - $_") }

            $optionStr = $options -join "`n"
            $width = "500px"
            $lineCount = $options.Count

            $chosen = $optionStr | rofi `
                -theme-str "window {width: $width;}" `
                -theme-str "listview {lines: $lineCount;}" `
                -theme-str "textbox-prompt-colon {str: '';}" `
                -dmenu `
                -p "Display Settings" `
                -mesg "Select a display configuration:" `
                -markup-rows

            if ($chosen) {
                $this.RunCmd($chosen)
            }
            else {
                $this.Log("No option selected.")
            }
        }
        $this.Log("Script completed successfully")
    }

    # Optional: Generate modeline (like cvt)
    [string] getModeline([int]$x, [int]$y, [int]$rate = 60) {
        $cvtOutput = cvt $x $y $rate
        return ($cvtOutput[1] -replace '^Modeline "\S+"\s+', '')
    }

    # Optional: Set resolution via newmode (advanced)
    [void] setResolution([int]$x, [int]$y, [int]$rate = 60) {
        $modeline = $this.getModeline($x, $y, $rate)
        $modeName = "${x}x${y}_$rate"
        $this.Log("Creating new mode: $modeName")
        xrandr --newmode $modeName $modeline
        # You'd then add it to an output — depends on context
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
$Public = Get-ChildItem "$PSScriptRoot/Public" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += Get-ChildItem "$PSScriptRoot/Private" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += $Public

foreach ($file in $scripts) {
    try {
        if ([string]::IsNullOrWhiteSpace($file.fullname)) { continue }
        . "$($file.fullname)"
    }
    catch {
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
