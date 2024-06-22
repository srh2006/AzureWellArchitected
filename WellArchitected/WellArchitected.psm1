#Requires -Modules Az.ResourceGraph,Az.Accounts

# Comment based help needs to be added.
# Many functions still require additional logic to be ported over.
# Retirements, support cases, ect. still need to be re-added to core logic.

function Connect-ToAzure 
{
    param
    (
        [string]$TenantID,
        [string[]]$SubscriptionIds,
        [string]$AzureEnvironment = 'AzureCloud'
    )

    # Connect To Azure Tenant
    If(-not (Get-AzContext))
    {
        Connect-AzAccount -Tenant $TenantID -WarningAction SilentlyContinue -Environment $AzureEnvironment
    }
}

function Get-AzureSubscriptionsFromTenant 
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]
        $TenantID,

        [Parameter()]
        [string]
        $AzureEnvironment
    )

    # Connect To Azure Tenant
    Connect-ToAzure -TenantID $TenantID -AzureEnvironment $AzureEnvironment
    $Subscriptions = Get-AzSubscription -TenantId $TenantID
    
    return $Subscriptions
}
  
function Test-Runbook 
{
    # Function is unused until purpose is determined.

    # Checks if a runbook file was provided and, if so, loads selectors and checks hashtables
    if (![string]::IsNullOrEmpty($RunbookFile)) {

      Write-Host "A runbook has been configured. Only checks configured in the runbook will be run."

      # Check that the runbook file actually exists
      if (Test-Path $RunbookFile -PathType Leaf) {

        # Try to load runbook JSON
        $RunbookJson = Get-Content -Raw $RunbookFile | ConvertFrom-Json

        # Try to load selectors
        $RunbookJson.selectors.PSObject.Properties | ForEach-Object {
          $Script:RunbookSelectors[$_.Name.ToLower()] = $_.Value
        }

        # Try to load checks
        $RunbookJson.checks.PSObject.Properties | ForEach-Object {
          $Script:RunbookChecks[$_.Name.ToLower()] = $_.Value
        }

        # Try to load query overrides
        $RunbookJson.query_overrides | ForEach-Object {
          $Script:RunbookQueryOverrides += [string]$_
        }
      }

      Write-Host "The provided runbook includes $($Script:RunbookChecks.Count.ToString()) check(s). Only checks configured in the runbook will be run."
    }
}

function Invoke-WellArchitectedKQLQuery
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string[]]$SubscriptionId,
        [Parameter(Mandatory)]
        $type,
        [Parameter(Mandatory)]
        $query,
        [Parameter(Mandatory)]
        $checkId,
        [Parameter(Mandatory)]
        $checkName,
        [Parameter(Mandatory)]
        $validationAction,
        $ResourceDetails
    )
    
    $QueryResultsCollection = @()

    try
    {
        Write-Debug -Message "Invoke-WellArchitectedKQLQuery: Start [Type:$type][SubscriptionId:$SubscriptionId]"
        $ResourceType = $ResourceDetails | Where-Object { $_.type -eq $type -and $_.subscriptionId -eq $SubscriptionId}
        if (-not [string]::IsNullOrEmpty($resourceType) -and $resourceType.count_ -lt 1000)
        {
            Write-Debug -Message "Invoke-WellArchitectedKQLQuery: Search-AzGraph Kickoff"
            # Execute the query and collect the results
            $queryResults = Search-AzGraph -Query $query -First 1000 -Subscription $SubscriptionId 
            $queryResults = $queryResults | Select -Property name,id,param1,param2,param3,param4,param5 -Unique

            foreach ($row in $queryResults)
            {
                $result = [PSCustomObject]@{
                    validationAction = [string]$validationAction
                    recommendationId = [string]$checkId
                    name             = [string]$row.name
                    id               = [string]$row.id
                    param1           = [string]$row.param1
                    param2           = [string]$row.param2
                    param3           = [string]$row.param3
                    param4           = [string]$row.param4
                    param5           = [string]$row.param5
                    checkName        = [string]$checkName
                    selector         = [string]$selector
                }
                $QueryResultsCollection += $result
            }
        }
        elseif (![string]::IsNullOrEmpty($resourceType) -and $resourceType.count_ -ge 1000)
        {
            $Loop = $resourceType.count_ / 1000
            $Loop = [math]::ceiling($Loop)
            $Looper = 0
            $Limit = 1

            while ($Looper -lt $Loop)
            {
                $queryResults = Search-AzGraph -Query ($query + '| order by id') `
                                               -Subscription $SubscriptionId `
                                               -Skip $Limit `
                                               -first 1000 `
                                               -ErrorAction SilentlyContinue

                foreach ($row in $queryResults)
                {
                    $result = 
                    [PSCustomObject]@{
                        validationAction = [string]$validationAction
                        recommendationId = [string]$checkId
                        name             = [string]$row.name
                        id               = [string]$row.id
                        param1           = [string]$row.param1
                        param2           = [string]$row.param2
                        param3           = [string]$row.param3
                        param4           = [string]$row.param4
                        param5           = [string]$row.param5
                        checkName        = [string]$checkName
                        selector         = [string]$selector
                    }
                
                    $QueryResultsCollection += $result
                }

                $Looper ++
                $Limit = $Limit + 1000
            }
        }
        if ($type -like '*azure-specialized-workloads/*')
        {
            $result = 
            [PSCustomObject]@{
                validationAction = [string]$validationAction
                recommendationId = [string]$checkId
                name             = [string]""
                id               = [string]""
                param1           = [string]""
                param2           = [string]""
                param3           = [string]""
                param4           = [string]""
                param5           = [string]""
                checkName        = [string]$checkName
                selector         = [string]$selector
            }

            $QueryResultsCollection += $result
        }
        Write-Debug -Message "Invoke-WellArchitectedKQLQuery: End of Try Block"
    }
    catch
    {
        # Report Error
        $errorMessage = $_.Exception.Message
        Write-Error "Error processing query results: $errorMessage"
    }

    Write-Debug -Message "Invoke-WellArchitectedKQLQuery: End"
    return $QueryResultsCollection
}

function Start-ResourceExtraction 
{
    # Most logic ported over to Get-WellArchitectedRecommendationsByID. Long term, all logic needs to be migrated and function to be renamed Get-WellArchitectedRecommendations
    # New funciton will support by Recommendation ID or Resource Type - missing today.
    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory)]
        [string[]]$SubscriptionIds,
        [Parameter(Mandatory)]
        [ValidateScript({$_ -match 'GitHub'})]
        [ValidateScript({Test-Path -Path $_})]
        [string]$GitHubRepoPath,
        [string[]]$ResourceGroups,
        [switch]$ExcludeNonARGValidated
    )

    $ShellPlatform = $PSVersionTable.Platform

    # Set the variables used in the loop
    foreach ($SubscriptionId in $SubscriptionIds)
    {
        # Get-AzSubscription can return junk in the first index. Continue onto the next index if so.
        if (-not $SubscriptionId)
        {
            Continue;
        }

        Set-AzContext -Subscription $SubscriptionId -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null

        if ([string]::IsNullOrEmpty($ResourceGroups))
        {
            $ResourceDetails = Get-WellArchitectedResourceTypes -SubscriptionID $SubscriptionId
        }
        else 
        {
            $ResourceDetails = Get-WellArchitectedResourceTypes -SubscriptionID $SubscriptionId -ResourceGroups $ResourceGroups
        }

        # Create the arrays used to store the kusto queries
        $kqlQueryMap = @{}
        $aprlKqlFiles = @()
        $ServiceNotAvailable = @()

        Set-Location -path $GitHubRepoPath;
        if ($ShellPlatform -eq 'Win32NT')
        {
            $clonePath = "$GitHubRepoPath\Azure-Proactive-Resiliency-Library-v2"
            $RootTypes = Get-ChildItem -Path "$clonePath\azure-resources\" -Directory
        }
        else
        {
            $clonePath = "$GitHubRepoPath/Azure-Proactive-Resiliency-Library-v2"
            $RootTypes = Get-ChildItem -Path "$clonePath/azure-resources/" -Directory
        }

        Set-Location -path $clonePath
        $GluedTypes = @()
        foreach ($RootType in $RootTypes)
        {
            $RootName = $RootType.Name
            $SubTypes = Get-ChildItem -Path $RootType -Directory
            foreach ($SubDir in $SubTypes)
            {
                $SubDirName = $SubDir.Name
                if (Get-ChildItem -Path $SubDir.FullName -File 'recommendations.yaml')
                {
                    if ($ShellPlatform -eq 'Win32NT')
                    {
                        $GluedTypes += (('Microsoft.' + $RootName + '/' + $SubDirName)).ToLower()
                    }
                    else 
                    {
                        $GluedTypes += (('Microsoft.' + $RootName + '\' + $SubDirName)).ToLower()
                    }
                }
            }
        }

        foreach ($Type in $ResourceDetails.type)
        {
            if ($Type.ToLower() -in $GluedTypes)
            {
                $Type = $Type.replace('microsoft.', '')
                $Provider = $Type.split('/')[0]
                $ResourceType = $Type.split('/')[1]

                if ($ShellPlatform -eq 'Win32NT')
                {
                    $Path = ($clonePath + '\azure-resources\' + $Provider + '\' + $ResourceType)
                    $aprlKqlFiles += Get-ChildItem -Path $Path -Filter "*.kql" -Recurse
                }
                else
                {
                    $Path = ($clonePath + '/azure-resources/')
                    $ProvPath = ($Provider + '/' + $ResourceType)
                    $aprlKqlFiles += Get-ChildItem -Path $Path -Filter "*.kql" -Recurse | Where-Object {$_.FullName -like "*$ProvPath*"}
                }
            }
            else
            {
                $ServiceNotAvailable += $Type
            }
        }

        # Checks if specialized workloads will be validated
        if ($SAP.IsPresent)
        {
            if ($ShellPlatform -eq 'Win32NT')
            {
                $aprlKqlFiles += Get-ChildItem -Path ($clonePath+ '\azure-specialized-workloads\sap') -Filter "*.kql" -Recurse
            }
            else
            {
                $aprlKqlFiles += Get-ChildItem -Path ($clonePath+ '/azure-specialized-workloads/sap') -Filter "*.kql" -Recurse
            }
        }

        if ($AVD.IsPresent)
        {
            if ($ShellPlatform -eq 'Win32NT')
            {
                $aprlKqlFiles += Get-ChildItem -Path ($clonePath+ '\azure-specialized-workloads\avd') -Filter "*.kql" -Recurse
            }
            else
            {
                $aprlKqlFiles += Get-ChildItem -Path ($clonePath+ '/azure-specialized-workloads/avd') -Filter "*.kql" -Recurse
            }
        }

        if ($AVS.IsPresent)
        {
            if ($ShellPlatform -eq 'Win32NT')
            {
                $aprlKqlFiles += Get-ChildItem -Path ($clonePath+ '\azure-specialized-workloads\avs') -Filter "*.kql" -Recurse
            }
            else
            {
                $aprlKqlFiles += Get-ChildItem -Path ($clonePath+ '/azure-specialized-workloads/avs') -Filter "*.kql" -Recurse
            }
        }

        if ($HPC.IsPresent)
        {
            if ($ShellPlatform -eq 'Win32NT')
            {
                $aprlKqlFiles += Get-ChildItem -Path ($clonePath+ '\azure-specialized-workloads\hpc') -Filter "*.kql" -Recurse
            }
            else
            {
                $aprlKqlFiles += Get-ChildItem -Path ($clonePath+ '/azure-specialized-workloads/hpc') -Filter "*.kql" -Recurse
            }
        }

        # Populates the QueryMap hashtable
        foreach ($aprlKqlFile in $aprlKqlFiles)
        {
            if ($ShellPlatform -eq 'Win32NT')
            {
                $kqlShort = [string]$aprlKqlFile.FullName.split('\')[-1]
            }
            else
            {
                $kqlShort = [string]$aprlKqlFile.FullName.split('/')[-1]
            }

            $kqlName = $kqlShort.split('.')[0]

            # Create APRL query map based on recommendation
            $kqlQueryMap[$kqlName] = $aprlKqlFile
        }

        $kqlFiles = $kqlQueryMap.Values
        $queries = @()

        # Loop through each KQL file and execute the queries
        foreach ($kqlFile in $kqlFiles)
        {
            if ($ShellPlatform -eq 'Win32NT')
            {
                $kqlshort = [string]$kqlFile.FullName.split('\')[-1]
            }
            else
            {
                $kqlshort = [string]$kqlFile.FullName.split('/')[-1]
            }

            $kqlname = $kqlshort.split('.')[0]

            # Read the query content from the file
            $baseQuery = Get-Content -Path $kqlFile.FullName | Out-String
            if ($ShellPlatform -eq 'Win32NT')
            {
                $typeRaw = $kqlFile.DirectoryName.split('\')
            }
            else
            {
                $typeRaw = $kqlFile.DirectoryName.split('/')
            }

            $kqltype = ('microsoft.' + $typeRaw[-3] + '/' + $typeRaw[-2])
            $checkId = $kqlname.Split("/")[-1].ToLower()

            $queries += `
            [PSCustomObject]@{
                checkId   = [string]$checkId
                checkName = [string]$null
                selector  = "APRL"
                query     = [string]$baseQuery
                type      = [string]$kqltype
                
            }
        }

        $ResourceResults = @()

        foreach ($queryDef in $queries)
        {
            $checkId = $queryDef.checkId
            $checkName = $queryDef.checkName
            $query = $queryDef.query
            $selector = $queryDef.selector
            $type = $queryDef.type

            if ($selector -eq 'APRL') 
            {
                Write-Host "[APRL]: Microsoft.$type - $checkId" -ForegroundColor Green -NoNewline
            }
            else 
            {
                Write-Host "[$selector]: $checkId" -ForegroundColor Green -NoNewline
            }

            # Validating if Query is Under Development
            if ($query -match "development")
            {
                Write-Host "Query $checkId under development - Validate Recommendation manually" -ForegroundColor Yellow
                $query = "resources | where type =~ '$type' | project name,id"
                $ResourceResults += Invoke-WellArchitectedKQLQuery -SubscriptionId $SubscriptionId -ResourceDetails $ResourceDetails -type $type -query $query -checkId $checkId -checkName $checkName -validationAction 'IMPORTANT - Query under development - Validate Recommendation manually'
            }
            elseif ($query -match "cannot-be-validated-with-arg")
            {
                Write-Host "IMPORTANT - Recommendation $checkId cannot be validated with ARGs - Validate Resources manually" -ForegroundColor Yellow
                $query = "resources | where type =~ '$type' | project name,id"
                $ResourceResults += Invoke-WellArchitectedKQLQuery -SubscriptionId $SubscriptionId -ResourceDetails $ResourceDetails -type $type -query $query -checkId $checkId -checkName $checkName -validationAction 'IMPORTANT - Recommendation cannot be validated with ARGs - Validate Resources manually'
            }
            else
            {
                Write-Debug -Message "Start-ResourceExtraction: Invoking Invoke-WellArchitectedKQLQuery - APRL Query"
                $ResourceResults += Invoke-WellArchitectedKQLQuery -SubscriptionId $SubscriptionId -ResourceDetails $ResourceDetails -type $type -query $query -checkId $checkId -checkName $checkName -validationAction 'Azure Resource Graph'  
            }
        }

        #Store all resourcetypes not in APRL
        foreach ($type in $ServiceNotAvailable)
        {
            Write-Host "Type $type Not Available In APRL - Validate Service manually" -ForegroundColor Yellow
            $query = "resources | where type =~ '$type' | project name,id"
            $ResourceResults += Invoke-WellArchitectedKQLQuery -SubscriptionId $SubscriptionId -ResourceDetails $ResourceDetails -type $type -query $query -checkId $type -checkName '' -validationAction 'IMPORTANT - Service Not Available In APRL - Validate Service manually if Applicable, if not Delete this line'
        }
    }
    
    if ($ExcludeNonARGValidated)
    {
        $ResourceResults = $ResourceResults | where {$_.ValidationAction -notmatch 'IMPORTANT'}
    }

    return $ResourceResults
}

function Get-WellArchitectedResourceTypes
{
    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionID,
        [string[]]$ResourceGroups
    )

    Write-Debug -Message 'Get-AzureResourceGroupDetails: Start'
    # If ResourceGroups is populated, iterate through the groups and grab the resources by type
    if (-not [string]::IsNullOrEmpty($ResourceGroups))
    {
        $resultAllResourceTypes = @()
        foreach ($RG in $ResourceGroups)
        {
            $resultAllResourceTypes += Search-AzGraph -Query "resources | where resourceGroup =~ '$RG' | summarize count() by type, subscriptionId" -Subscription $SubscriptionID
        }
    }
    else
    {
        # Extract and display resource types with the query with subscriptions, we need this to filter the subscriptions later
        $resultAllResourceTypes = Search-AzGraph -Query "resources | summarize count() by type, subscriptionId" -Subscription $SubscriptionId

    }

    Write-Debug -Message 'Get-AzureResourceGroupDetails: End'
    return $resultAllResourceTypes
}

function Get-WellArchitectedRecommendationsByID
{
    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory)]
        [string[]]
        $RecommendationIds,

        [Parameter(Mandatory)]
        [string[]]
        $SubscriptionIds,

        [Parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $GitHubRepoPath,

        [Parameter()]
        [string[]]
        $ResourceGroups
    )

    Write-Debug -Message "Get-WellArchitectedRecommendationsByID: START [RecommendationIds:$RecommendationIds][SubscriptionIds:$SubscriptionIds][ResourceGroups:$ResourceGroups]"
    $ShellPlatform = $PSVersionTable.Platform
    Set-Location -path $GitHubRepoPath;

    if ($ShellPlatform -eq 'Win32NT')
    {
        $AzureResourcePath =  "$GitHubRepoPath\Azure-Proactive-Resiliency-Library-v2\azure-resources\"
        $SpecializedResourcePath = "$GitHubRepoPath\Azure-Proactive-Resiliency-Library-v2\azure-specialized-workloads\"
    }
    else
    {
        $AzureResourcePath =  "$GitHubRepoPath/Azure-Proactive-Resiliency-Library-v2/azure-resources/"
        $SpecializedResourcePath = "$GitHubRepoPath/Azure-Proactive-Resiliency-Library-v2/azure-specialized-workloads/"
    }

    $KQLCollection = @()
    # Iterate through RecommendationIds and find corresponding KQL Files in Default Azure-Resources or Azure-Specialized-Workloads
    foreach ($RecommendationId in $RecommendationIds)
    {
        $KQLCollection += Get-ChildItem -Path $AzureResourcePath -Filter "*.kql" -Recurse | where {$_.Name -match $RecommendationId}
        $KQLCollection += Get-ChildItem -Path $SpecializedResourcePath -Filter "*.kql" -Recurse | where {$_.Name -match $RecommendationId}
    }

    $KQLQueries = ConvertTo-WellArchitectedQueriesFromKQLPath -KQLFileFullPaths $($KQLCollection.FullName)
    
    $RecommendationResults = @()
    foreach ($SubscriptionId in $SubscriptionIds)
    {
        if ($ResourceGroups)
        {
            $ResourceDetails = Get-WellArchitectedResourceTypes -SubscriptionID $SubscriptionId `
                                                                -ResourceGroups $ResourceGroups
        }
        else 
        {
            $ResourceDetails = Get-WellArchitectedResourceTypes -SubscriptionID $SubscriptionId
        }

        foreach ($queryDef in $KQLQueries)
        {
            $checkId = $queryDef.checkId
            $checkName = $queryDef.checkName
            $query = $queryDef.query
            $selector = $queryDef.selector
            $type = $queryDef.type

            if ($selector -eq 'APRL') 
            {
                Write-Verbose -Message "[APRL]: Microsoft.$type - $checkId"
            }
            else 
            {
                Write-Verbose -Message "[$selector]: $checkId"
            }

            Write-Verbose -Message "Get-WellArchitectedRecommendationsByID: QueryDef Variables [CheckId:$checkId][checkName:$checkName][query:$query][type:$type]"

            # Validating if Query is Under Development
            if ($query -match "development")
            {
                Write-Verbose -Message "Query $checkId under development - Validate Recommendation manually"
                $query = "resources | where type =~ '$type' | project name,id"
                $RecommendationResults += Invoke-WellArchitectedKQLQuery -SubscriptionId $SubscriptionId `
                                                                         -ResourceDetails $ResourceDetails `
                                                                         -type $type `
                                                                         -query $query `
                                                                         -checkId $checkId `
                                                                         -checkName $checkName `
                                                                         -validationAction 'IMPORTANT - Query under development - Validate Recommendation manually'
            }
            elseif ($query -match "cannot-be-validated-with-arg")
            {
                Write-Verbose -Message "IMPORTANT - Recommendation $checkId cannot be validated with ARGs - Validate Resources manually"
                $query = "resources | where type =~ '$type' | project name,id"
                $RecommendationResults += Invoke-WellArchitectedKQLQuery -SubscriptionId $SubscriptionId `
                                                                         -ResourceDetails $ResourceDetails `
                                                                         -type $type `
                                                                         -query $query `
                                                                         -checkId $checkId `
                                                                         -checkName $checkName `
                                                                         -validationAction 'IMPORTANT - Recommendation cannot be validated with ARGs - Validate Resources manually'
            }
            else
            {
                Write-Verbose -Message "Invoking ARG Query for [CheckID:$checkid]"
                $RecommendationResults += Invoke-WellArchitectedKQLQuery -SubscriptionId $SubscriptionId `
                                                                         -ResourceDetails $ResourceDetails `
                                                                         -type $type `
                                                                         -query $query `
                                                                         -checkId $checkId `
                                                                         -checkName $checkName `
                                                                         -validationAction 'Azure Resource Graph'  
            }
        }
    }

    Write-Debug -Message "Get-WellArchitectedRecommendationsByID: END [RecommendationIds:$RecommendationIds][SubscriptionIds:$SubscriptionIds][ResourceGroups:$ResourceGroups]"
    return $RecommendationResults
}

function Compare-WellArchitectedRecommendations
{
    # Empty function - Logic needed
    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory)]
        $OriginalRecommendations,

        [Parameter(Mandatory)]
        $NewRecommendations
    )
}

function ConvertTo-WellArchitectedQueriesFromKQLPath
{
    [CmdletBinding()]
    param 
    (
        [Parameter()]
        [string[]]
        $KQLFileFullPaths
    )

    $queries = @()
    $ShellPlatform = $PSVersionTable.Platform
    
    # Populates the QueryMap hashtable
    foreach ($KQLFileFullPath in $KQLFileFullPaths)
    {
        if ($ShellPlatform -eq 'Win32NT')
        {
            [string]$kqlShort = $KQLFileFullPath.split('\')[-1]
        }
        else
        {
            [string]$kqlShort = $KQLFileFullPath.split('/')[-1]
        }

        $kqlName = $kqlShort.split('.')[0]
        $SplitDirectory = @()

        # Read the query content from the file
        $baseQuery = Get-Content -Path $KQLFileFullPath | Out-String
        $ParentDirectory = Split-Path -Path $KQLFileFullPath -Parent
        if ($ShellPlatform -eq 'Win32NT')
        {
            [string[]]$SplitDirectory = $ParentDirectory.split('\')
            [string]$checkId = $kqlname.Split("\")[-1].ToLower()
        }
        else
        {
            [string[]]$SplitDirectory = $ParentDirectory.split('/')
            [string]$checkId = $kqlname.Split("/")[-1].ToLower()
        }

        $kqltype = ('microsoft.' + $SplitDirectory[-3] + '/' + $SplitDirectory[-2])

        $queries += `
        [PSCustomObject]@{
            checkId   = [string]$checkId
            checkName = [string]$null
            selector  = "APRL"
            query     = [string]$baseQuery
            type      = [string]$kqltype
        }
    }

    return $queries
}

function Get-WellArchitectedRecommendationDefinitions
{
    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $GitHubRepoPath,

        [Parameter()]
        [string[]]
        $RecommendationIds
    )
    
    Write-Debug -Message "Get-WellArchitectedRecommendationDefinitions: START [RecommendationIds:$RecommendationIds][GitHubRepoPath:$GitHubRepoPath]"
    $LibraryPath = $GitHubRepoPath + '\Azure-Proactive-Resiliency-Library-v2'
    
    # Collect Services Definitions from corresponding YAML files
    $ServicesYAML = @()
    $ServicesYAML += Get-ChildItem -Path ($LibraryPath + '\azure-resources') -Filter "recommendations.yaml" -Recurse
    $ServicesYAML += Get-ChildItem -Path ($LibraryPath + '\azure-specialized-workloads') -Filter "recommendations.yaml" -Recurse

    $ServicesYAMLContent = @()
    foreach ($YAML in $ServicesYAML)
    {
        if (-not [string]::IsNullOrEmpty($YAML))
        {
            $ServicesYAMLContent += Get-Content -Path $YAML | ConvertFrom-Yaml
        }
    }

    # This should be optimized in future updates
    $MatchedRecommendationCollection = @()
    if ($RecommendationIds)
    {
        foreach ($RecommendationId in $RecommendationIds)
        {
            $MatchedRecommendationCollection += $ServicesYAMLContent | where {$_.aprlGuid -match $RecommendationId}
        }

        # Update collection with matched recommendations prior to returning
        $ServicesYAMLContent = $MatchedRecommendationCollection
    }

    Write-Debug -Message "Get-WellArchitectedRecommendationDefinitions: END [RecommendationIds:$RecommendationIds][GitHubRepoPath:$GitHubRepoPath]"
    return $ServicesYAMLContent
}
