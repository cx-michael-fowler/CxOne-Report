using module .\CxOneAPIModule
#--------------------------------------------------------------------------------------------------------------------------------------------------------------
#region Help

<#
.Synopsis
Script to export data for the Checkmarx One Report

.Description
Creates the file data.zip in the same location as script. This zip has five CSV files used in conjunction with the 
Checkmarx One report Excel to generate a report.

NOTE: This script may run for a very long time if the number of scans is very large. Try reducing the scanDays value as needed

Usage
Help
    .\CxOne-Report.ps1 -help [<CommonParameters>]

Report
    .\CxOne-Report.ps1 [-scanDays] [-silentLogin -apiKey] [<CommonParameters>]
    

.Notes
Version:     2.0
Date:        24/07/2026
Written by:  Michael Fowler
Contact:     michael.fowler@checkmarx.com

Change Log
Version    Detail
-----------------
1.0        Original version
1.1        Updated to rename Secrets to SSCS
2.0        Added languages and state data

  
.PARAMETER help
Display help

.PARAMETER silentLogin
Log into Checkmarx One using the provided API Key. Is optional and if not used a prompt will appear for the key

.PARAMETER apiKey
The API Key used to log into Checkamrx One. Is mandatory with silentLogin

.PARAMETER scanDays
The number of days for which scans will be returned. Must be a value between 1 and 365. Is optional and will default to 90 if not set


#>

#endregion
#--------------------------------------------------------------------------------------------------------------------------------------------------------------
#region Parameters

[CmdletBinding(DefaultParametersetName='Help')] 
Param (

    [Parameter(ParameterSetName='Help',Mandatory=$false, HelpMessage="Display help")]
    [switch]$help,

    [Parameter(ParameterSetName='CxOne',Mandatory=$false, HelpMessage="Days to run report for")]
    [ValidateRange(1, 365)]
    [int]$scanDays = 90,

    [Parameter(ParameterSetName='CxOne',Mandatory=$false,HelpMessage="Logon silently using provided API Key")]
    [switch]$silentLogin

)

#endregion
#--------------------------------------------------------------------------------------------------------------------------------------------------------------
#region Dynamic Parameters

DynamicParam {
    if ($silentLogin) {
        # Define parameter attributes
        $paramAttributes = New-Object -Type System.Management.Automation.ParameterAttribute
        $paramAttributes.Mandatory = $true
        $paramAttributes.HelpMessage = "The API Key used to login"

        # Create collection of the attributes
        $paramAttributesCollect = New-Object -Type System.Collections.ObjectModel.Collection[System.Attribute]
        $paramAttributesCollect.Add($paramAttributes)

        # Create parameter with name, type, and attributes
        $dynParam = New-Object -Type System.Management.Automation.RuntimeDefinedParameter("apiKey", [string], $paramAttributesCollect)

        # Add parameter to parameter dictionary and return the object
        $paramDictionary = New-Object -Type System.Management.Automation.RuntimeDefinedParameterDictionary
        $paramDictionary.Add("apiKey", $dynParam)
        return $paramDictionary
    }
}

#endregion
#--------------------------------------------------------------------------------------------------------------------------------------------------------------
#region Begin

Begin {
    
    $apiKey = $PSBoundParameters['apiKey']

    #----------------------------------------------------------------------------------------------------------------------------------------------------------
    #region Functions

    # Get Dates, Contributer counts and Versions
    Function Export-GeneralData {
        param (
            [Parameter(Mandatory=$true)][CxOneConnection]$conn,
            [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.ArrayList]$files
        )
        
        $outputFile = Join-Path -Path "$env:TEMP" -ChildPath "general.csv"
        $general = [PSCustomObject]@{
            "Start Date" = ([datetime]::Today).AddDays(-$scanDays).ToString("yyyy-MM-dd")
            "End Date" = ([datetime]::Today).ToString("yyyy-MM-dd")
        }
        $uri = "$($conn.baseUri)/api/contributors"
        $response = ApiCall { Invoke-RestMethod $uri -Method GET -Headers $conn.Headers} $conn
        $general | Add-Member -MemberType NoteProperty -Name "Licenced Contributors" -Value ([int]$response.allowedContributors)
        $general | Add-Member -MemberType NoteProperty -Name "Current Contributors" -Value ([int]$response.currentContributors)
        $uri = "$($conn.baseUri)/api/versions"
        $response = ApiCall { Invoke-RestMethod $uri -Method GET -Headers $conn.Headers} $conn
        $response.psobject.Properties | ForEach-Object { $general | Add-Member -MemberType NoteProperty -Name "$($_.Name) version" -Value $_.Value }
        $general | export-csv $outputFile -NoTypeInformation
        $files.Add($outputFile) | out-null
    }

    #Get Application data
    Function Export-Apps {
        param (
            [Parameter(Mandatory=$true)][CxOneConnection]$conn,
            [Parameter(Mandatory=$true)][System.Collections.ArrayList]$files
        )

        $outputFile = Join-Path -Path "$env:TEMP" -ChildPath "applications.csv"
        (Get-Applications $conn -getRisk).values | 
            Select-Object ApplicationID,ApplicationName,Description,CreatedAt,UpdatedAt,Criticality,@{N=’ProjectIds’; E={$_.ProjectIdsString}},RiskScore,RiskSeverity | 
            export-csv $outputFile -NoTypeInformation
        $files.Add($outputFile) | out-null
    }

    #Get project data
    Function Export-Projects {
        param (
            [Parameter(Mandatory=$true)][CxOneConnection]$conn,
            [Parameter(Mandatory=$true)][System.Collections.ArrayList]$files
        )

        $outputFile = Join-Path -Path "$env:TEMP" -ChildPath "projects.csv"
        (Get-AllProjects $conn -getBranches).Values | 
            Select-Object ProjectID,ProjectName,CreatedAt,UpdatedAt,MainBranch,Origin,Criticality,PrivatePackage,@{N=’Branches’; E={$_.BranchesString}} | 
            export-csv $outputFile -NoTypeInformation
        $files.Add($outputFile) | out-null
    }

    #Get Scans data. Return scans to retrieve severity counters
    Function Export-Scans {
        param (
            [Parameter(Mandatory=$true)][CxOneConnection]$conn,
            [Parameter(Mandatory=$true)][int]$scanDays,
            [Parameter(Mandatory=$true)][System.Collections.ArrayList]$files
        )

        #Scans
        $outputFile = Join-Path -Path "$env:TEMP" -ChildPath "scans.csv"
        $scans  = Get-ScansByDays $conn Completed,Failed,Partial $scanDays -getLanguages
        $scans.Values |
            Select-Object ScanID,ProjectId,ProjectName,Status,Branch,Loc,CreatedAt,StartDate,EndDate,Runtime,
                          @{N=’Engines’;E={$_.EnginesString}},Initiator,SourceType,SourceOrigin,
                          @{N=’ScannedLanguages’;E={$_.SastScanMetrics.ScannedLanguagesString}},
                          @{N=’NotScannedLanguages’; E={$_.SastScanMetrics.DetectedButNotScannedLanguagesString}} | 
            export-csv $outputFile -NoTypeInformation
        $files.Add($outputFile) | out-null

        #Engine Status records
        $outputFile = Join-Path -Path "$env:TEMP" -ChildPath "statuses.csv"
        $scans.values | ForEach-Object {
            $id = $_.ScanID
            $_.Statuses | ForEach-Object {
                [PSCustomObject]@{
                    ScanID = $id
                    EngineName = $_.EngineName
                    Status = $_.Status
                    Details = $_.Details
                    StartDate = $_.StartDate
                    EndDate = $_.EndDate
                    Runtime = $_.Runtime
                }
            }
        } | export-csv $outputFile -NoTypeInformation
        $files.Add($outputFile) | out-null

        return $scans
    }

    #Export Scan Summaries
    Function Export-ScanSummaries {
        param (
            [Parameter(Mandatory=$true)][CxOneConnection]$conn,
            [Parameter(Mandatory=$true)][System.Collections.Generic.Dictionary[String, Scan]]$scans,
            [Parameter(Mandatory=$true)][System.Collections.ArrayList]$files
        )

        $summary = Get-ScanSummaries $conn $scans
        Export-Severities $summary $files
        Export-States $summary $files
    }

    #Export Severities
    Function Export-Severities {
        param (
            [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.Generic.Dictionary[String, ScanSummary]]$summary,
            [Parameter(Mandatory=$true)][System.Collections.ArrayList]$files
        )      
        
        $outputFile = Join-Path -Path "$env:TEMP" -ChildPath "severityCounts.csv"
        $summary.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{
                ScanID = $_.Key
                Total_Vulnerabilties = $_.Value.Totals.Severities.Total
                Total_Critical = $_.Value.Totals.Severities.Critical
                Total_High = $_.Value.Totals.Severities.High
                Total_Medium = $_.Value.Totals.Severities.Medium
                Total_Low = $_.Value.Totals.Severities.Low
                Total_Info = $_.Value.Totals.Severities.Info
                
                Sast_Total_Vulnerabilties = $_.Value.Sast.Severities.Total
                Sast_Critical = $_.Value.Sast.Severities.Critical
                Sast_High = $_.Value.Sast.Severities.High
                Sast_Medium = $_.Value.Sast.Severities.Medium
                Sast_Low = $_.Value.Sast.Severities.Low
                Sast_Info = $_.Value.Sast.Severities.Info
                
                Kics_Total_Vulnerabilties = $_.Value.Kics.Severities.Total
                Kics_Critical = $_.Value.Kics.Severities.Critical
                Kics_High = $_.Value.Kics.Severities.High
                Kics_Medium = $_.Value.Kics.Severities.Medium
                Kics_Low = $_.Value.Kics.Severities.Low
                Kics_Info = $_.Value.Kics.Severities.Info

                Sca_Total_Vulnerabilties = $_.Value.Sca.Severities.Total
                Sca_Critical = $_.Value.Sca.Severities.Critical
                Sca_High = $_.Value.Sca.Severities.High
                Sca_Medium = $_.Value.Sca.Severities.Medium
                Sca_Low = $_.Value.Sca.Severities.Low
                Sca_Info = $_.Value.Sca.Severities.Info

                Packages_Total_Vulnerabilties = $_.Value.Packages.Severities.Total
                Packages_Critical = $_.Value.Packages.Severities.Critical
                Packages_High = $_.Value.Packages.Severities.High
                Packages_Medium = $_.Value.Packages.Severities.Medium
                Packages_Low = $_.Value.Packages.Severities.Low
                Packages_Info = $_.Value.Packages.Severities.Info

                Api_Total_Vulnerabilties = $_.Value.Api.Severities.Total
                Api_Critical = $_.Value.Api.Severities.Critical
                Api_High = $_.Value.Api.Severities.High
                Api_Medium = $_.Value.Api.Severities.Medium
                Api_Low = $_.Value.Api.Severities.Low
                Api_Info = $_.Value.Api.Severities.Info

                SSCS_Total_Vulnerabilties = $_.Value.SSCS.Severities.Total
                SSCS_Critical = $_.Value.SSCS.Severities.Critical
                SSCS_High = $_.Value.SSCS.Severities.High
                SSCS_Medium = $_.Value.SSCS.Severities.Medium
                SSCS_Low = $_.Value.SSCS.Severities.Low
                SSCS_Info = $_.Value.SSCS.Severities.Info

                Containers_Total_Vulnerabilties = $_.Value.Containers.Severities.Total
                Containers_Critical = $_.Value.Containers.Severities.Critical
                Containers_High = $_.Value.Containers.Severities.High
                Containers_Medium = $_.Value.Containers.Severities.Medium
                Containers_Low = $_.Value.Containers.Severities.Low
                Containers_Info = $_.Value.Containers.Severities.Info
            }
        } | export-csv $outputFile -NoTypeInformation
        $files.Add($outputFile) | out-null
    }

    #Export States
    Function Export-States {
        param (
            [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.Generic.Dictionary[String, ScanSummary]]$summary,
            [Parameter(Mandatory=$true)][System.Collections.ArrayList]$files
        ) 
        
        $outputFile = Join-Path -Path "$env:TEMP" -ChildPath "stateCounts.csv"
        $summary.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{
                ScanID = $_.Key
                Total_Confirmed = $_.Value.Totals.States.Confirmed
                Total_ToVerify = $_.Value.Totals.States.ToVerify
                Total_Urgent = $_.Value.Totals.States.Urgent
                Total_NotExploitable = $_.Value.Totals.States.NotExploitable
                Total_ProposedNotExploitable = $_.Value.Totals.States.ProposedNotExploitable

                Sast_Confirmed  = $_.Value.Sast.States.Confirmed
                Sast_ToVerify = $_.Value.Sast.States.ToVerify
                Sast_Medium = $_.Value.Sast.States.Urgent
                Sast_NotExploitable = $_.Value.Sast.States.NotExploitable
                Sast_ProposedNotExploitable = $_.Value.Sast.States.ProposedNotExploitable

                Kics_Confirmed  = $_.Value.Kics.States.Confirmed
                Kics_ToVerify = $_.Value.Kics.States.ToVerify
                Kics_Urgent = $_.Value.Kics.States.Urgent
                Kics_NotExploitable = $_.Value.Kics.States.NotExploitable
                Kics_ProposedNotExploitable = $_.Value.Kics.States.ProposedNotExploitable

                Sca_Confirmed  = $_.Value.Sca.States.Confirmed
                Sca_ToVerify = $_.Value.Sca.States.ToVerify
                Sca_Urgent = $_.Value.Sca.States.Urgent
                Sca_NotExploitable = $_.Value.Sca.States.NotExploitable
                Sca_ProposedNotExploitable = $_.Value.Sca.States.ProposedNotExploitable

                Packages_Confirmed  = $_.Value.Packages.States.Confirmed
                Packages_ToVerify = $_.Value.Packages.States.ToVerify
                Packages_Urgent = $_.Value.Packages.States.Urgent
                Packages_NotExploitable = $_.Value.Packages.States.NotExploitable
                Packages_ProposedNotExploitable = $_.Value.Packages.States.ProposedNotExploitable

                Api_Confirmed  = $_.Value.Api.States.Confirmed
                Api_ToVerify = $_.Value.Api.States.ToVerify
                Api_Urgent = $_.Value.Api.States.Medium
                Api_NotExploitable = $_.Value.Api.States.NotExploitable
                Api_ProposedNotExploitable = $_.Value.Api.States.ProposedNotExploitable

                SSCS_Confirmed  = $_.Value.SSCS.States.Confirmed
                SSCS_ToVerify = $_.Value.SSCS.States.High
                SSCS_Urgent = $_.Value.SSCS.States.Urgent
                SSCS_NotExploitable = $_.Value.SSCS.States.NotExploitable
                SSCS_ProposedNotExploitable = $_.Value.SSCS.States.ProposedNotExploitable

                Containers_Confirmed  = $_.Value.Containers.States.Confirmed
                Containers_ToVerify = $_.Value.Containers.States.ToVerify
                Containers_Urgent = $_.Value.Containers.States.Urgent
                Containers_NotExploitable = $_.Value.Containers.States.NotExploitable
                Containers_ProposedNotExploitable = $_.Value.Containers.States.ProposedNotExploitable
            }
        } | export-csv $outputFile -NoTypeInformation
        $files.Add($outputFile) | out-null        
    }

 

    #endregion
    #----------------------------------------------------------------------------------------------------------------------------------------------------------
}

#endregion
#--------------------------------------------------------------------------------------------------------------------------------------------------------------
#region Process

Process {

    #Display help if called
    if ($help) {
        Get-Help $MyInvocation.InvocationName -Full | Out-String
        exit
    }

    Write-Host "=========="
    $start = Get-Date
    Write-Host "Processing Started at $(Get-Date -Format "HH:mm:ss")"

    # Log onto Checkmarx One 
    Write-Host "Logging into Checkmarx One"
    if ($silentLogin) { $conn = New-SilentConnection $apiKey }
    else { $conn = New-Connection }
    Write-Host "Login completed"

    # ArrayList of Files Created
    $files = [System.Collections.ArrayList]::new()

     #General Data
    Write-Host "Retrieving General Information"
    Export-GeneralData $conn $files
    Write-Host "General details written to file"

    #Applications
    Write-Host "Retrieving Applications"
    Export-Apps $conn $files
    Write-Host "Applications written to file"

    #Projects
    Write-Host "Retrieving Projects"
    Export-Projects $conn $files
    Write-Host "Projects written to file"

    #Scans and Statuses
    Write-Host "Retrieving Scans"
    $scans = Export-Scans $conn $scanDays $files
    Write-Host "Scans written to file"

    #Severity and States Counters
    Write-Host "Retrieving Scan Summeries"
    Export-ScanSummaries $conn $scans $files
    Write-Host "Scan Summeries written to file"

    #Zip files and save to script location
    Compress-Archive -Path $files -DestinationPath "$PSScriptRoot\data.zip" -Force
    Remove-Item -Path $files
        
    $end = Get-Date
    $runtime = (New-TimeSpan –Start $start –End $end).ToString("hh\:mm\:ss")
    Write-Host "Processing Completed at $(Get-Date -Format "HH:mm:ss") with a runtime of $runtime"
    Write-Host "=========="
    Write-Host ""
    Read-Host -Prompt "The data has been successfully exported to data.zip. Press Enter to exit"
}

#endregion
#--------------------------------------------------------------------------------------------------------------------------------------------------------------