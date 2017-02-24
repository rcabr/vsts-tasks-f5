##
## PUBLIC
##
function F5-ChangePoolStatus(
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $username,
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $unsecurepassword,
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $ltm,
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $pool,
	[string][Parameter(Mandatory=$true)][ValidateSet("Enable", "Disable", "ForceOffline")] $actionMode,
    [string][Parameter(Mandatory=$true)] $failIfConnections
)
{
    # Get auth token
    $tokencode = GetAuthToken -ltm $ltm -username $username -unsecurepassword $unsecurepassword

    # Query for members of a pool
    $members = GetPoolMembers -ltm $ltm -pool $pool -authtokencode $tokencode
    
    $failures = 0;
    $previousState;
    [System.Collections.ArrayList]$successfulMembers = [System.Collections.ArrayList]@();

    foreach ($member in $members) {
   
        # check current connections
        if ($failIfConnections -eq $True -and $actionMode -ne "Enable") # never check when Enabling
        {
            # query for stats (current connections)
            $stats = QueryStatsForMember -ltm $ltm -pool $pool -member $member -authtokencode $tokencode
            $currentConnections = $stats.'serverside.curConns'.value;
            $previousState = $stats.'status.availabilityState'.description;

            # if connections not 0
            if ($currentConnections -eq $null -or $currentConnections -ne 0) {
                $failures++;
                Write-VstsTaskError "$($member.name) has $currentConnections current connections. Will NOT change availability.";
                break;
            }
        }

        # Send command
        $success = SendActionRequest -actionMode $actionMode -authtokencode $tokencode -member $member;
        if ($success) {
            $ignoreMe = $successfulMembers.Add($member);
        }
        else { $failures++; }
    }

    if ($failures -gt 0) # if ALL didn't succeed
    {
        Write-VstsTaskError "$failures pool members failed. $($successfulMembers.Count) require rollback.";

        if ($successfulMembers.Count -ge 1) { # we had at least one successful change; rollback
            AttemptRollback -previousState $previousState -successfulMembers $successfulMembers -authtokencode $tokencode;
        }
        
        Write-VstsSetResult -Result Failed -Message "Failed to change availability of $failures pool members.  Please see log for details.";
    }
}

############## PRIVATE FUNCTIONS ###################

##
## Attempts to rollback all the $successfulMembers to the specified $previousState
##
function AttemptRollback(
    [System.Collections.ArrayList][Parameter(Mandatory=$true)][ValidateNotNull()] $successfulMembers,
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $previousState,
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $authtokencode
)
{
    $rollbackSuccessCount = 0;
    $rollbackAction;

    switch ($previousState) {
        "available" { $rollbackAction = "Enable"; }
        "disabled" { $rollbackAction = "Disable"; }
        default { $rollbackAction = "ForceOffline"; }
    }
            
    foreach ($member in $successfulMembers) {
        Write-Warning "Rollback: Attempting to $rollbackAction $($member.name)."
        $rollbackSuccess = SendActionRequest -actionMode $rollbackAction -authtokencode $authtokencode -member $member;
        if ($rollbackSuccess) { $rollbackSuccessCount++; }
    }
    Write-VstsTaskError "Rolled back $rollbackSuccessCount pool members of $($successfulMembers.Count) that were updated.";
}

##
## Requests the specified action (Enable, Disable, ForceOffline) 
## to be taken on the specified Local Traffic Manager pool member.
## Returns $true if successful, $false if unsuccessful.
##
function SendActionRequest (
    [string][Parameter(Mandatory=$true)][ValidateSet("Enable", "Disable", "ForceOffline")] $actionMode,
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $authtokencode,
    [PSObject][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $member
)
{
    try {
        Write-VstsTaskVerbose "Sending $actionMode request for $($member.name)";
        $memberSelfLink = $member.selfLink.Replace("localhost", $ltm)
        $action = CreateActionRequest -actionMode $actionMode;
        $responseJSON = Invoke-WebRequest -Uri $memberSelfLink `
            -ContentType application/json `
            -Method PUT `
            -Headers @{"X-F5-AUTH-TOKEN"="$authtokencode"} `
            -Body $action;
        $response = ($responseJSON.Content | ConvertFrom-Json);
        Write-VstsTaskDebug "Request to $actionMode $($member.name) completed. Response: state= $($response.state), session= $($response.session)";
        return $true;
    }
    catch {
        $message = $_.Exception;
        if(Get-Member -InputObject $_ -name "ErrorDetails" -Membertype Properties){
            $err = ConvertFrom-Json $_.ErrorDetails;
            if ($err.code -ne $null) {
                $message = "($($err.code)) $($err.message)";
            }
        }
        Write-Warning $message;
        return $false;
    }
}

##
## Queries the statistics for the specified Local Traffic Manager pool member.
##
function QueryStatsForMember(
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $ltm,
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $pool,
    [PSObject][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $member,
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $authtokencode
)
{
    try {
        Write-VstsTaskDebug "Querying status of pool member $($member.name)";
        $memberPath = ($member.fullPath).Replace("/","~");
        $statsResponse = Invoke-WebRequest `
            -Uri https://$ltm/mgmt/tm/ltm/pool/$pool/members/$memberPath/stats?ver=12.1.0 `
            -ContentType application/json `
            -Method GET `
            -Headers @{"X-F5-AUTH-TOKEN"="$authtokencode"}
        return ParseJsonResponse-F5Stats($statsResponse);
    }
    catch {
        $message = $_.Exception;
        if(Get-Member -inputobject $_ -name "ErrorDetails" -Membertype Properties){
            $err = ConvertFrom-Json $_.ErrorDetails;
            if ($err.code -ne $null) {
                $message = "($($err.code)) $($err.message)";
            }
        }
        Write-VstsTaskError $message;
        exit;
    }
}

##
## Parses a JSON response returned from querying a pool member's stats,
## and returns a PSObject containing the stat 'entries'.
##
function ParseJsonResponse-F5Stats(
    [Microsoft.PowerShell.Commands.HtmlWebResponseObject][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $response
)
{
    # discard the 3 outer layers ({}) of the JSON document so that ConvertFrom-Json will convert deeply-nested properties properly (workaround)
    $innerContent = $response.Content;
    for ($i = 1; $i -le 3; $i++)
    {
        $innerContent = $innerContent.Substring($innerContent.IndexOf("{",2), $innerContent.LastIndexOf("}") - $innerContent.IndexOf("{",2))
    }

    $nestedStats = ($innerContent  | ConvertFrom-Json);

    return $nestedStats.entries;
}

##
## Authenticates to the specified Local Traffic Manager, 
## and returns an authentication token which will accompany any further requests.
##
function GetAuthToken(
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $ltm,
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $username,
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $unsecurepassword
)
{
    try {
        Write-VstsTaskVerbose "Authenticating to $ltm as $username..."

        $loginUri = "https://$ltm/mgmt/shared/authn/login";
        $loginRequestBody = "{'username':'$username', 'password':'$unsecurepassword', 'loginProviderName':'tmos'}";
        $authJSON = Invoke-WebRequest -Uri $loginUri `
            -ContentType application/json `
            -Method POST `
            -Body $loginRequestBody;

        $token = ($authJSON.Content | ConvertFrom-Json);
        $tokencode = $token.token.token;
        Write-VstsTaskDebug "Successfully authenticated to $ltm as $username";
        return $tokencode;
    }
    catch {
        $message = $_.Exception;
        if(Get-Member -inputobject $_ -name "ErrorDetails" -Membertype Properties){
            $err = ConvertFrom-Json $_.ErrorDetails;
            if ($err.code -ne $null) {
                $message = "($($err.code)) $($err.message)";
            }
        }
        Write-VstsTaskError $message;
        exit;
    }
}

##
## Queries the specified Local Traffic Manager pool for all members,
## and returns the members as an array of PSObjects.
##
function GetPoolMembers(
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $ltm,
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $pool,
    [string][Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()] $authtokencode
)
{
    try {
        Write-VstsTaskVerbose "Getting members of pool $pool from $ltm";
        $responseJSON = Invoke-WebRequest -Uri https://$ltm/mgmt/tm/ltm/pool/$pool/members `
            -ContentType application/json `
            -Method GET `
            -Headers @{"X-F5-AUTH-TOKEN"="$authtokencode"};
        $response = ($responseJSON.Content | ConvertFrom-Json)
        $members = $response.items
        return $members;
    }
    catch {
        $message = $_.Exception;
        if(Get-Member -inputobject $_ -name "ErrorDetails" -Membertype Properties){
            $err = ConvertFrom-Json $_.ErrorDetails;
            if ($err.code -ne $null) {
                $message = "($($err.code)) $($err.message)";
            }
        }
        Write-VstsTaskError $message;
        exit;
    }
}

##
## Returns the JSON request body needed to perform the specified action (Enable, Disable, ForceOffline).
##
function CreateActionRequest(
    [string][Parameter(Mandatory=$true)][ValidateSet("Enable", "Disable", "ForceOffline")] $actionMode
)
{
    # This is the action to take on a pool member. 1 = Enable, 2 = Disable, 3 = ForceOffline
    switch ($actionMode) 
    {
        "Disable" {
            $action = '{"state": "user-up", "session": "user-disabled" }'
        } 
        "ForceOffline" {
            $action = '{"state": "user-down", "session": "user-disabled" }'
        } 
        default {  #"Enable"
            $action = '{"state": "user-up", "session": "user-enabled" }'
        }
    }
    return $action;
}


