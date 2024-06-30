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

function Invoke-WellArchitectedKQLQuery
{
    <#
        .SYNOPSIS
        Executes Well Architected KQL Query based on provided Azure Resource Details.
        -- TODO: Reduce excess parameters and clean up output.

        .DESCRIPTION
        Requires READ access to provided Azure subscriptions.
        Will EXECUTE corresponding Well Architected KQL queries against provided Azure Subscription.

        .PARAMETER $SubscriptionIds
        Specifies the Subscriptions to target with Well Architected Evaluation.

        .INPUTS
        All parameters are required.

        .OUTPUTS
        Returns KQL Query execution results as an object.

        .EXAMPLE
        --TODO Add example.
    #>

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
        [Parameter(Mandatory)]
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

function Get-WellArchitectedResourceTypes
{
    <#
        .SYNOPSIS
        Gets the Azure Resource Types from the provided Subscription/Resource Groups.

        .DESCRIPTION
        Requires READ access to provided Azure subscriptions.
        Will return all Azure Resource Types discovered in subscription regardless if there is Well Architected coverage for that type.

        .PARAMETER $SubscriptionIds
        Specifies the Subscriptions to target with Well Architected Evaluation.

        .PARAMETER ResourceGroups
        OPTIONAL: Allows the user to provide resource groups to filter shared subscriptions down to specific resources.

        .INPUTS
        SubscriptionIds and RecommendationIDs are required.
        They are passed a string arrays.

        .OUTPUTS
        Returns Azure Resource Types from provided subscription.

        .EXAMPLE
        --TODO Add example.
    #>

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

function Get-WellArchitectedRecommendations
{
     <#
        .SYNOPSIS
        Gets Well Architected Recommendations for Azure provided Azure Subscription/ResourceGroups.
        Default behavior returns Recommendations by Resource Types of Azure Subscription.

        .DESCRIPTION
        Requires READ access to provided Azure subscriptions.
        Will evaluate Azure and return recommendations for remediation.

        .PARAMETER $SubscriptionIds
        Specifies the Subscriptions to target with Well Architected Evaluation.

        .PARAMETER RecommendationIDs
        Specifies the RecommendationIDs you would like to filter on.
        This will return only recommendations that match your provided RecommendationIDs.
        If not provided, it will return recommendations by Resource Type

        .PARAMETER GitHubRepoPath
        Specifies the GitHub Repo FilePath where the Recommedation.YAML files are stored.
        -- TODO: Dependency on the local GitHub Repo should be removed in the future.

        .PARAMETER ResourceGroups
        OPTIONAL: Allows the user to provide resource groups to filter shared subscriptions down to specific resources.

        .INPUTS
        SubscriptionIds, RecommendationIDs, GitHubRepoPath are all required.

        .OUTPUTS
        Returns Well Architected Recommendations based on Azure Subscription provided.

        .EXAMPLE
        PS > Get-WellArchitectedRecommendations -SubscriptionIds $subscriptionId -GitHubRepoPath $githubRepoPath | Select -first 1

        validationAction       : Azure Resource Graph
        recommendationId       : 1549b91f-2ea0-4d4f-ba2a-4596becbe3de
        name                   : DefaultBackupVault-southcentralus
        id                     : /subscriptions/7d154fd1-2e97-4a32-a079-c2b72fc3aeb2/resourceGroups/DefaultResourceGroup-SCUS/providers/Microsoft.RecoveryServices/vaults/DefaultBackupVault-southcen 
                                tralus
        param1                 : CrossRegionRestore: Disabled
        param2                 : StorageReplicationType: GeoRedundant
        param3                 : 
        param4                 : 
        param5                 : 
        checkName              : 
        selector               : APRL
        Description            : Enable Cross Region Restore for your GRS Recovery Services Vault
        RecommendationCategory : Disaster Recovery
        LearnMoreLink          : {Set Cross Region Restore, Azure Backup Best Practices, Minimum Role Requirements for Cross Region Restore, Recovery Services Vault}
        Priority               : Medium
    #>

    [CmdletBinding()]
    param 
    (
        [Parameter(Mandatory)]
        [string[]]
        $SubscriptionIds,

        [Parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $GitHubRepoPath,

        [Parameter()]
        [string[]]
        $RecommendationIds,

        [Parameter()]
        [string[]]
        $ResourceGroups,

        [Parameter()]
        [ValidateSet('avd','avs','sap','hpc')]
        [string[]]$SpecialIzedWorkloads
    )

    Write-Debug -Message "Get-WellArchitectedRecommendations: START [RecommendationIds:$RecommendationIds][SubscriptionIds:$SubscriptionIds][ResourceGroups:$ResourceGroups]"
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

    # If RecommendationIds has been provided, search for KQL based on it.
    if ($RecommendationIds)
    {
        # Iterate through RecommendationIds and find corresponding KQL Files in Default Azure-Resources or Azure-Specialized-Workloads
        foreach ($RecommendationId in $RecommendationIds)
        {
            $KQLCollection += Get-ChildItem -Path $AzureResourcePath -Filter "*.kql" -Recurse | where {$_.Name -match $RecommendationId}
            $KQLCollection += Get-ChildItem -Path $SpecializedResourcePath -Filter "*.kql" -Recurse | where {$_.Name -match $RecommendationId}
        }
    }
    else 
    {
        # Grab KQLs by resource Type if recommendation Ids not provided.
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

        $ServiceNotAvailable = @()
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

        if ($SpecializedWorkloads)
        {
            foreach ($Workload in $SpecializedWorkloads)
            {
                $aprlKqlFiles += Get-ChildItem -Path ($SpecializedResourcePath  + $Workload) -Filter "*.kql" -Recurse
            }
        }

        $KQLCollection = $aprlKqlFiles
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

        #Store all resourcetypes not in APRL
        foreach ($type in $ServiceNotAvailable)
        {
            Write-Host "Type $type Not Available In APRL - Validate Service manually" -ForegroundColor Yellow
            $query = "resources | where type =~ '$type' | project name,id"
            $RecommendationResults += Invoke-WellArchitectedKQLQuery -SubscriptionId $SubscriptionId -ResourceDetails $ResourceDetails -type $type -query $query -checkId $type -checkName '' -validationAction 'IMPORTANT - Service Not Available In APRL - Validate Service manually if Applicable, if not Delete this line'
        }
    }

    # Grab the Well Architected Definitions and assign them to the Results Set
    if (-not $RecommendationIds)
    {
        $RecommendationIds = $RecommendationResults | Select -ExpandProperty RecommendationId -Unique
    }

    $Definitions = Get-WellArchitectedRecommendationDefinitions -GitHubRepoPath $GitHubRepoPath -RecommendationIds $RecommendationIds
    Write-Debug -Message "Get-WellArchitectedRecommendations: Definition Count: $($Definitions.Count)"
    Write-Debug -Message "Get-WellArchitectedRecommendations: Recommendation Results:$($RecommendationResults.Count)"

    $FullRecommendationCollection = @()
    foreach ($RecommendationResult in $RecommendationResults)
    {
        $FullRecommendation = $RecommendationResult | Select *,Description,RecommendationCategory,LearnMoreLink,Priority

        $DefinitionMatch = $Definitions | where {$_.aprlGuid -match $RecommendationResult.RecommendationId}
        if ($DefinitionMatch)
        {
            $FullRecommendation.Description = $DefinitionMatch.description
            $FullRecommendation.RecommendationCategory = $DefinitionMatch.recommendationControl
            $FullRecommendation.LearnMoreLink = $DefinitionMatch.learnMoreLink
            $FullRecommendation.Priority = $DefinitionMatch.recommendationImpact
        }
            
        $FullRecommendationCollection += $FullRecommendation
    }

    Write-Debug -Message "Get-WellArchitectedRecommendations: END [RecommendationIds:$RecommendationIds][SubscriptionIds:$SubscriptionIds][ResourceGroups:$ResourceGroups]"
    return $FullRecommendationCollection
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
    <#
        .SYNOPSIS
        Converts Well Architected KQL Queries to Objects from GitHub Repo File Paths to .KQL files.

        .DESCRIPTION
        All KQL Queries are stored within the Azure Resiliency Git Hub Repo and can be read/returned as objects using this function.

        .PARAMETER KQLFileFullPaths
        Specifies the GitHub Repo FilePath where the .KQL files are stored that need to be converted to Objects.
        "C:\Users\Username\Documents\GitHub\Azure-Proactive-Resiliency-Library-v2\azure-resources\Storage\storageAccounts\kql\1b965cb9-7629-214e-b682-6bf6e450a100.kql"

        .INPUTS
        KQL Full File Paths are the only required Input Paramter
        EXAMPLE:"C:\Users\Username\Documents\GitHub\Azure-Proactive-Resiliency-Library-v2\azure-resources\Storage\storageAccounts\kql\1b965cb9-7629-214e-b682-6bf6e450a100.kql"

        .OUTPUTS
        Returns Well Architected Queries as an Object
    #>

    [CmdletBinding()]
    param 
    (
        [Parameter()]
        [string[]]
        $KQLFileFullPaths
    )

    $queries = @()
    $ShellPlatform = $PSVersionTable.Platform
    
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
    <#
        .SYNOPSIS
        Gets Well Architected Recommendations from local Azure Resiliency GitHub Repo.

        .DESCRIPTION
        All recommendation definitions are stored as YAML and returned as an object once returned by this Cmdlet.

        .PARAMETER GitHubRepoPath
        Specifies the GitHub Repo FilePath where the Recommedation.YAML files are stored.
        -- TODO: Dependency on the local GitHub Repo should be removed in the future.

        .PARAMETER RecommendationIDs
        OPTIONAL: Specifies the RecommendationIDs you would like to filter on.
        This will return only recommendations that match your provided RecommendationIDs.

        .INPUTS
        GitHub Repo FilePath is the only required Paramter

        .OUTPUTS
        Returns Well Architected Recommendations as an Object

        .EXAMPLE
        PS> Get-WellArchitectedRecommendationDefinitions -GitHubRepoPath $GitHubRepoPath -RecommendationIds $recommendationid              

        publishedToLearn            : False
        recommendationMetadataState : Active
        potentialBenefits           : Ensures backend uptime monitoring.
        recommendationResourceType  : Microsoft.Network/loadBalancers
        publishedToAdvisor          : False
        description                 : Use Health Probes to detect backend instances availability
        recommendationControl       : Monitoring and Alerting
        longDescription             : Health probes are used by Azure Load Balancers to determine the status of backend endpoints. Using custom health probes that are aligned with vendor
                                    recommendations enhances understanding of backend availability and facilitates monitoring of backend services for any impact.

        tags                        : 
        automationAvailable         : arg
        recommendationImpact        : High
        learnMoreLink               : {Load Balancer Health Probe Overview}
        recommendationTypeId        : 
        pgVerified                  : True
        aprlGuid                    : e5f5fcea-f925-4578-8599-9a391e888a60
    #>

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
    return ($ServicesYAMLContent | ConvertFrom-HashTableToObject)
}

function ConvertFrom-HashTableToObject
{
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory,ValueFromPipeline)]
        [hashtable]$HashTable
    )

    begin
    {
        $ReturnObject = @()
    }
    process
    {
        $HashTable | ForEach-Object `
        {
            $Result = New-Object psobject;
            foreach ($key in $_.keys) 
            {
                $Result | Add-Member -MemberType NoteProperty -Name $key -Value $_[$key]
            }

            $ReturnObject += $Result;
        }
    }
    end
    {
        return $ReturnObject
    }
}