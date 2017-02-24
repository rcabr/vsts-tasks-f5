[CmdletBinding()]
Param()

Trace-VstsEnteringInvocation $MyInvocation

Try
{

    [string]$ltm = Get-VstsInput -Name ltm -Require
    [string]$pool = Get-VstsInput -Name pool -Require
    [string]$action = Get-VstsInput -Name action -Require
    [string]$username = Get-VstsInput -Name userName -Require
    [string]$passwd = Get-VstsInput -Name password -Require
    [string]$failIfConnections = Get-VstsInput -Name failIfConnections -Default "False"

	. .\F5-ChangePoolStatus-Intern.ps1;

    F5-ChangePoolStatus -username $username -unsecurepassword $passwd -ltm $ltm -pool $pool -actionMode $action -failIfConnections $failIfConnections
}
finally
{
	Trace-VstsLeavingInvocation $MyInvocation
}