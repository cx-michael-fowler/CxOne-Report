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
Version:     1.1
Date:        05/03/2026
Written by:  Michael Fowler
Contact:     michael.fowler@checkmarx.com

Change Log
Version    Detail
-----------------
1.0        Original version
1.1        Updated to rename Secrets to SSCS

  
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
    Function Get-GeneralData {
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
    Function Get-Apps {
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
    Function Get-Projects {
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
    Function Get-Scans {
        param (
            [Parameter(Mandatory=$true)][CxOneConnection]$conn,
            [Parameter(Mandatory=$true)][int]$scanDays,
            [Parameter(Mandatory=$true)][System.Collections.ArrayList]$files
        )

        #Scans
        $outputFile = Join-Path -Path "$env:TEMP" -ChildPath "scans.csv"
        $scans  = Get-ScansByDays $conn Completed,Failed,Partial $scanDays
        $scans.Values |
            Select-Object ScanID,ProjectId,ProjectName,Status,Branch,Loc,CreatedAt,StartDate,EndDate,Runtime,@{N=’Engines’; E={$_.EnginesString}},Initiator,SourceType,SourceOrigin | 
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

    #Get Severity Counters
    Function Get-Severities {
        param (
            [Parameter(Mandatory=$true)][CxOneConnection]$conn,
            [Parameter(Mandatory=$true)][System.Collections.Generic.Dictionary[String, Scan]]$scans,
            [Parameter(Mandatory=$true)][System.Collections.ArrayList]$files
        )

        $outputFile = Join-Path -Path "$env:TEMP" -ChildPath "counts.csv"
        $counts = Get-SeverityCounters $conn $scans
        $counts.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{
                ScanID = $_.Key
                Total_Vulnerabilties = $_.Value.Totals.Total
                Total_Critical = $_.Value.Totals.Critical
                Total_High = $_.Value.Totals.High
                Total_Medium = $_.Value.Totals.Medium
                Total_Low = $_.Value.Totals.Low
                Total_Info = $_.Value.Totals.Info
                Sast_Total_Vulnerabilties = $_.Value.Sast.Total
                Sast_Critical = $_.Value.Sast.Critical
                Sast_High = $_.Value.Sast.High
                Sast_Medium = $_.Value.Sast.Medium
                Sast_Low = $_.Value.Sast.Low
                Sast_Info = $_.Value.Sast.Info
                Kics_Total_Vulnerabilties = $_.Value.Kics.Total
                Kics_Critical = $_.Value.Kics.Critical
                Kics_High = $_.Value.Kics.High
                Kics_Medium = $_.Value.Kics.Medium
                Kics_Low = $_.Value.Kics.Low
                Kics_Info = $_.Value.Kics.Info
                Sca_Total_Vulnerabilties = $_.Value.Sca.Total
                Sca_Critical = $_.Value.Sca.Critical
                Sca_High = $_.Value.Sca.High
                Sca_Medium = $_.Value.Sca.Medium
                Sca_Low = $_.Value.Sca.Low
                Sca_Info = $_.Value.Sca.Info
                Packages_Total_Vulnerabilties = $_.Value.Packages.Total
                Packages_Critical = $_.Value.Packages.Critical
                Packages_High = $_.Value.Packages.High
                Packages_Medium = $_.Value.Packages.Medium
                Packages_Low = $_.Value.Packages.Low
                Packages_Info = $_.Value.Packages.Info
                Api_Total_Vulnerabilties = $_.Value.Api.Total
                Api_Critical = $_.Value.Api.Critical
                Api_High = $_.Value.Api.High
                Api_Medium = $_.Value.Api.Medium
                Api_Low = $_.Value.Api.Low
                Api_Info = $_.Value.Api.Info
                SSCS_Total_Vulnerabilties = $_.Value.SSCS.Total
                SSCS_Critical = $_.Value.SSCS.Critical
                SSCS_High = $_.Value.SSCS.High
                SSCS_Medium = $_.Value.SSCS.Medium
                SSCS_Low = $_.Value.SSCS.Low
                SSCS_Info = $_.Value.SSCS.Info
                Containers_Total_Vulnerabilties = $_.Value.Containers.Total
                Containers_Critical = $_.Value.Containers.Critical
                Containers_High = $_.Value.Containers.High
                Containers_Medium = $_.Value.Containers.Medium
                Containers_Low = $_.Value.Containers.Low
                Containers_Info = $_.Value.Containers.Info
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
    Get-GeneralData $conn $files
    Write-Host "General details written to file"

    #Applications
    Write-Host "Retrieving Applications"
    Get-Apps $conn $files
    Write-Host "Applications written to file"

    #Projects
    Write-Host "Retrieving Projects"
    Get-Projects $conn $files
    Write-Host "Projects written to file"

    #Scans and Statuses
    Write-Host "Retrieving Scans"
    $scans = Get-Scans $conn $scanDays $files
    Write-Host "Scans written to file"

    #Severity Counters
    Write-Host "Retrieving Severity Counters"
    Get-Severities $conn $scans $files
    Write-Host "Severity counts written to file"

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