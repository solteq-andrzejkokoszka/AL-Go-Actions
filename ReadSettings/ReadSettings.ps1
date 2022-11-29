Param(
    [Parameter(HelpMessage = "The GitHub actor running the action", Mandatory = $false)]
    [string] $actor,
    [Parameter(HelpMessage = "The GitHub token running the action", Mandatory = $false)]
    [string] $token,
    [Parameter(HelpMessage = "Specifies the parent telemetry scope for the telemetry signal", Mandatory = $false)]
    [string] $parentTelemetryScopeJson = '7b7d',
    [Parameter(HelpMessage = "Project folder", Mandatory = $false)]
    [string] $project = ".",
    [Parameter(HelpMessage = "Indicates whether you want to retrieve the list of project list as well", Mandatory = $false)]
    [bool] $getprojects,
    [Parameter(HelpMessage = "Specifies the pattern of the environments you want to retreive (or empty for no environments)", Mandatory = $false)]
    [string] $getenvironments = "",
    [Parameter(HelpMessage = "Specifies whether you want to include production environments", Mandatory = $false)]
    [bool] $includeProduction,
    [Parameter(HelpMessage = "Indicates whether this is called from a release pipeline", Mandatory = $false)]
    [bool] $release,
    [Parameter(HelpMessage = "Specifies which properties to get from the settings file, default is all", Mandatory = $false)]
    [string] $get = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$telemetryScope = $null
$bcContainerHelperPath = $null

# IMPORTANT: No code that can fail should be outside the try/catch

try {
    . (Join-Path -Path $PSScriptRoot -ChildPath "..\AL-Go-Helper.ps1" -Resolve)
    $BcContainerHelperPath = DownloadAndImportBcContainerHelper -baseFolder $ENV:GITHUB_WORKSPACE

    import-module (Join-Path -path $PSScriptRoot -ChildPath "..\TelemetryHelper.psm1" -Resolve)
    $telemetryScope = CreateScope -eventId 'DO0079' -parentTelemetryScopeJson $parentTelemetryScopeJson

    if ($project  -eq ".") { $project = "" }

    $baseFolder = Join-Path $ENV:GITHUB_WORKSPACE $project
   
    $settings = ReadSettings -baseFolder $baseFolder -workflowName $env:GITHUB_WORKFLOW
    if ($get) {
        $getSettings = $get.Split(',').Trim()
    }
    else {
        $getSettings = @($settings.Keys)
    }

    if ($ENV:GITHUB_EVENT_NAME -eq "pull_request") {
        $settings.doNotSignApps = $true
    }

    if ($settings.appBuild -eq [int32]::MaxValue) {
        $settings.versioningStrategy = 15
    }

    if ($settings.versioningstrategy -ne -1) {
        if ($getSettings -contains 'appBuild' -or $getSettings -contains 'appRevision') {
            switch ($settings.versioningStrategy -band 15) {
                0 { # Use RUN_NUMBER and RUN_ATTEMPT
                    $settings.appBuild = $settings.runNumberOffset + [Int32]($ENV:GITHUB_RUN_NUMBER)
                    $settings.appRevision = [Int32]($ENV:GITHUB_RUN_ATTEMPT) - 1
                }
                1 { # Use RUN_ID and RUN_ATTEMPT
                    OutputError -message "Versioning strategy 1 is no longer supported"
                }
                2 { # USE DATETIME
                    $settings.appBuild = [Int32]([DateTime]::UtcNow.ToString('yyyyMMdd'))
                    $settings.appRevision = [Int32]([DateTime]::UtcNow.ToString('HHmmss'))
                }
                15 { # Use maxValue
                    $settings.appBuild = [Int32]::MaxValue
                    $settings.appRevision = 0
                }
                default {
                    OutputError -message "Unknown version strategy $versionStrategy"
                    exit
                }
            }
        }
    }

    $outSettings = @{}
    $getSettings | ForEach-Object {
        $setting = $_.Trim()
        $outSettings += @{ "$setting" = $settings."$setting" }
        Add-Content -Path $env:GITHUB_ENV -Value "$setting=$($settings."$setting")"
    }

    $outSettingsJson = $outSettings | ConvertTo-Json -Compress
    Add-Content -Path $env:GITHUB_OUTPUT -Value "SettingsJson=$outSettingsJson"
    Add-Content -Path $env:GITHUB_ENV -Value "Settings=$OutSettingsJson"
    Write-Host "SettingsJson=$outSettingsJson"

    $gitHubRunner = $settings.githubRunner.Split(',').Trim() | ConvertTo-Json -compress
    Add-Content -Path $env:GITHUB_OUTPUT -Value "GitHubRunnerJson=$githubRunner"
    Write-Host "GitHubRunnerJson=$githubRunner"

    if ($getprojects) {

        $buildProjects = @()
        if ($settings.Projects) {
            $projects = $settings.projects
        }
        else {
            $projects = @(Get-ChildItem -Path $ENV:GITHUB_WORKSPACE -Directory -Recurse -Depth 2 | Where-Object { Test-Path (Join-Path $_.FullName '.AL-Go\Settings.json') -PathType Leaf } | ForEach-Object { $_.FullName.Substring("$ENV:GITHUB_WORKSPACE".length+1) })
        }
        if ($projects) {
            Write-Host "All Projects: $($projects -join ', ')"
            if (!$settings.alwaysBuildAllProjects -and ($ENV:GITHUB_EVENT_NAME -eq "pull_request" -or $ENV:GITHUB_EVENT_NAME -eq "push" -or ($ENV:GITHUB_EVENT_NAME -eq "workflow_run" -and (Test-Path (Join-Path $ENV:GITHUB_WORKSPACE '.PullRequestFilesChanged'))))) {
                if ($ENV:GITHUB_EVENT_NAME -eq "workflow_run" -and (Test-Path (Join-Path $ENV:GITHUB_WORKSPACE '.PullRequestFilesChanged'))) {
                    $filesChanged = @(Get-Content (Join-Path $ENV:GITHUB_WORKSPACE '.PullRequestFilesChanged') -Encoding UTF8)
                }
                else {
                    $headers = @{             
                        "Authorization" = "token $token"
                        "Accept" = "application/vnd.github.baptiste-preview+json"
                    }
                    $ghEvent = Get-Content $ENV:GITHUB_EVENT_PATH -encoding UTF8 | ConvertFrom-Json
                    if ($ENV:GITHUB_EVENT_NAME -eq "pull_request") {
                        $url = "$($ENV:GITHUB_API_URL)/repos/$($ENV:GITHUB_REPOSITORY)/compare/$($ghEvent.pull_request.base.sha)...$($ENV:GITHUB_SHA)"
                    }
                    else {
                        $url = "$($ENV:GITHUB_API_URL)/repos/$($ENV:GITHUB_REPOSITORY)/compare/$($ghEvent.before)...$($ghEvent.after)"
                    }
                    if ($ghEvent.before -eq '0'*40) {
                        $buildProjects = $projects
                    }
                    else {
                        $response = InvokeWebRequest -Headers $headers -Uri $url | ConvertFrom-Json
                        $filesChanged = @($response.files | ForEach-Object { $_.filename })
                    }
                }
                if ($filesChanged.Count -ge 250) {
                    Write-Host "More than 250 files modified, building all projects"
                    $buildProjects = $projects
                }
                else {
                    Write-Host "Modified files:"
                    $filesChanged | Out-Host
                    $buildProjects = @($projects | Where-Object {
                        $project = $_
                        $buildProject = $false
                        if (Test-Path -path (Join-Path $ENV:GITHUB_WORKSPACE "$project\.AL-Go\Settings.json")) {
                            $projectFolders = Get-ProjectFolders -baseFolder $ENV:GITHUB_WORKSPACE -project $project -token $token -includeAlGoFolder -includeApps -includeTestApps
                            $projectFolders | ForEach-Object {
                                if ($filesChanged -like "$_/*") { $buildProject = $true }
                            }
                        }
                        $buildProject
                    })
                    Write-Host "Modified projects: $($buildProjects -join ', ')"
                }
            }
            else {
                $buildProjects = $projects
            }
            if ($settings.useProjectDependencies) {
                $buildAlso = @{}
                $buildOrder = @{}
                $projectDependencies = @{}
                AnalyzeProjectDependencies -basePath $ENV:GITHUB_WORKSPACE -projects $projects -buildOrder ([ref]$buildOrder) -buildAlso ([ref]$buildAlso) -projectDependencies ([ref]$projectDependencies)
                $buildProjects = @($buildProjects | ForEach-Object { $_; if ($buildAlso.ContainsKey("$_")) { $buildAlso."$_" } } | Select-Object -Unique)
                Write-Host "Building projects: $($buildProjects -join ', ')"
                $projectDependenciesJson = $projectDependencies | ConvertTo-Json -Compress
                $buildOrderJson = $buildOrder | ConvertTo-Json -Compress
                Add-Content -Path $env:GITHUB_OUTPUT -Value "ProjectDependenciesJson=$projectDependenciesJson"
                Add-Content -Path $env:GITHUB_OUTPUT -Value "BuildOrderJson=$buildOrderJson"
                Add-Content -Path $env:GITHUB_OUTPUT -Value "BuildOrderDepth=$($buildOrder.Count)"
                Write-Host "ProjectDependenciesJson=$projectDependenciesJson"
                Write-Host "BuildOrderJson=$buildOrderJson"
                Write-Host "BuildOrderDepth=$($buildOrder.Count)"
            }
        }
        if (Test-Path ".AL-Go" -PathType Container) {
            $buildProjects += @(".")
        }
        if ($buildProjects.Count -eq 1) {
            $projectsJSon = "[$($buildProjects | ConvertTo-Json -compress)]"
        }
        else {
            $projectsJSon = $buildProjects | ConvertTo-Json -compress
        }
        Add-Content -Path $env:GITHUB_OUTPUT -Value "ProjectsJson=$projectsJson"
        Add-Content -Path $env:GITHUB_ENV -Value "Projects=$projectsJson"
        Write-Host "ProjectsJson=$projectsJson"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "ProjectCount=$($buildProjects.Count)"
        Write-Host "ProjectCount=$($buildProjects.Count)"
    }

    if ($getenvironments) {
        $environments = @()
        $headers = @{ 
            "Authorization" = "token $token"
            "Accept"        = "application/vnd.github.v3+json"
        }
        $url = "$($ENV:GITHUB_API_URL)/repos/$($ENV:GITHUB_REPOSITORY)/environments"
        try {
            $environments = @((InvokeWebRequest -Headers $headers -Uri $url -ignoreErrors | ConvertFrom-Json).environments | ForEach-Object { $_.Name })
        } 
        catch {}
        $environments = @($environments+@($settings.Environments) | Where-Object { $_ -ne "github-pages" } | Where-Object { 
            if ($includeProduction) {
                $_ -like $getEnvironments -or $_ -like "$getEnvironments (PROD)" -or $_ -like "$getEnvironments (Production)" -or $_ -like "$getEnvironments (FAT)" -or $_ -like "$getEnvironments (Final Acceptance Test)"
            }
            else {
                $_ -like $getEnvironments -and $_ -notlike '* (PROD)' -and $_ -notlike '* (Production)' -and $_ -notlike '* (FAT)' -and $_ -notlike '* (Final Acceptance Test)'
            }
        })

        $json = @{"matrix" = @{ "include" = @() }; "fail-fast" = $false }
        $environments | Select-Object -Unique | ForEach-Object { 
            $environmentGitHubRunnerKey = "$($_.Split(' ')[0])_GitHubRunner"
            $os = $settings."runs-on".Split(',').Trim()
            if (([HashTable]$settings).ContainsKey($environmentGitHubRunnerKey)) {
                $os = $settings."$environmentGitHubRunnerKey".Split(',').Trim()
            }
            $json.matrix.include += @{ "environment" = $_; "os" = "$($os | ConvertTo-Json -compress)" }
        }
        $environmentsJson = $json | ConvertTo-Json -Depth 99 -compress
        Add-Content -Path $env:GITHUB_OUTPUT -Value "EnvironmentsJson=$environmentsJson"
        Add-Content -Path $env:GITHUB_ENV -Value "Environments=$environmentsJson"
        Write-Host "EnvironmentsJson=$environmentsJson"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "EnvironmentCount=$($environments.Count)"
        Write-Host "EnvironmentCount=$($environments.Count)"
    }

    TrackTrace -telemetryScope $telemetryScope
}
catch {
    OutputError -message "ReadSettings action failed.$([environment]::Newline)Error: $($_.Exception.Message)$([environment]::Newline)Stacktrace: $($_.scriptStackTrace)"
    TrackException -telemetryScope $telemetryScope -errorRecord $_
    exit
}
finally {
    CleanupAfterBcContainerHelper -bcContainerHelperPath $bcContainerHelperPath
}
