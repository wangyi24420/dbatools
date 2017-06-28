function Copy-DbaResourceGovernor {
	<#
		.SYNOPSIS
			Migrates Resource Pools

		.DESCRIPTION
			By default, all non-system resource pools are migrated. If the pool already exists on the destination, it will be skipped unless -Force is used. 
				
			The -ResourcePool parameter is autopopulated for command-line completion and can be used to copy only specific objects.

		.PARAMETER Source
			Source SQL Server. You must have sysadmin access and server version must be SQL Server version 2008 or higher.

		.PARAMETER SourceSqlCredential
			Allows you to login to servers using SQL Logins as opposed to Windows Auth/Integrated/Trusted. To use:

			$scred = Get-Credential, then pass $scred object to the -SourceSqlCredential parameter. 

			Windows Authentication will be used if DestinationSqlCredential is not specified. SQL Server does not accept Windows credentials being passed as credentials. 	
			To connect as a different Windows user, run PowerShell as that user.

		.PARAMETER Destination
			Destination Sql Server. You must have sysadmin access and server version must be SQL Server version 2008 or higher.

		.PARAMETER DestinationSqlCredential
			Allows you to login to servers using SQL Logins as opposed to Windows Auth/Integrated/Trusted. To use:

			$dcred = Get-Credential, then pass this $dcred to the -DestinationSqlCredential parameter. 

			Windows Authentication will be used if DestinationSqlCredential is not specified. SQL Server does not accept Windows credentials being passed as credentials. 	
			To connect as a different Windows user, run PowerShell as that user.

		.PARAMETER ResourcePool
			The resource pool(s) to process - this list is auto populated from the server. If unspecified, all resource pools will be processed.

		.PARAMETER ExcludeResourcePool
			The resource pool(s) to exclude - this list is auto populated from the server

		.PARAMETER WhatIf 
			Shows what would happen if the command were to run. No actions are actually performed. 

		.PARAMETER Confirm 
			Prompts you for confirmation before executing any changing operations within the command. 

		.PARAMETER Force
			If policies exists on destination server, it will be dropped and recreated.

		.PARAMETER Silent 
			Use this switch to disable any kind of verbose messages

		.NOTES
			Tags: Migration, ResourceGovernor
			Author: Chrissy LeMaire (@cl), netnerds.net
			Requires: sysadmin access on SQL Servers

			Website: https://dbatools.io
			Copyright: (C) Chrissy LeMaire, clemaire@gmail.com
			License: GNU GPL v3 https://opensource.org/licenses/GPL-3.0

		.LINK
			https://dbatools.io/Copy-DbaResourceGovernor

		.EXAMPLE   
			Copy-DbaResourceGovernor -Source sqlserver2014a -Destination sqlcluster

			Copies all extended event policies from sqlserver2014a to sqlcluster, using Windows credentials. 

		.EXAMPLE   
			Copy-DbaResourceGovernor -Source sqlserver2014a -Destination sqlcluster -SourceSqlCredential $cred

			Copies all extended event policies from sqlserver2014a to sqlcluster, using SQL credentials for sqlserver2014a and Windows credentials for sqlcluster.

		.EXAMPLE   
			Copy-DbaResourceGovernor -Source sqlserver2014a -Destination sqlcluster -WhatIf

			Shows what would happen if the command were executed.
	#>
	[CmdletBinding(DefaultParameterSetName = "Default", SupportsShouldProcess = $true)]
	param (
		[parameter(Mandatory = $true)]
		[DbaInstanceParameter]$Source,
		[parameter(Mandatory = $true)]
		[DbaInstanceParameter]$Destination,
		[System.Management.Automation.PSCredential]$SourceSqlCredential,
		[System.Management.Automation.PSCredential]$DestinationSqlCredential,
		[switch]$Force
	)

	begin {

		$sourceserver = Connect-SqlInstance -SqlInstance $Source -SqlCredential $SourceSqlCredential
		$destserver = Connect-SqlInstance -SqlInstance $Destination -SqlCredential $DestinationSqlCredential
		
		$source = $sourceserver.DomainInstanceName
		$destination = $destserver.DomainInstanceName

		if ($sourceserver.versionMajor -lt 10 -or $destserver.versionMajor -lt 10) {
			throw "Resource Governor is only supported in SQL Server 2008 and above. Quitting."
		}
	}
	process {

		if ($Pscmdlet.ShouldProcess($destination, "Updating Resource Governor settings")) {
			if ($destserver.Edition -notmatch 'Enterprise' -and $destserver.Edition -notmatch 'Datacenter' -and $destserver.Edition -notmatch 'Developer') {
				Write-Warning "The resource governor is not available in this edition of SQL Server. You can manipulate resource governor metadata but you will not be able to apply resource governor configuration. Only Enterprise edition of SQL Server supports resource governor."
			}
			else {
				try {
					$sql = $sourceserver.resourceGovernor.Script() | Out-String
					$sql = $sql -replace [Regex]::Escape("'$source'"), "'$destination'"
					Write-Verbose $sql
					Write-Output "Updating Resource Governor settings"
					$null = $destserver.ConnectionContext.ExecuteNonQuery($sql)
				}
				catch {
					Write-Exception $_
				}
			}
		}
		
		# Pools
		if ($respools.length -gt 0) {
			$pools = $sourceserver.ResourceGovernor.ResourcePools | Where-Object { $respools -contains $_.Name }
		}
		else {
			$pools = $sourceserver.ResourceGovernor.ResourcePools | Where-Object { $_.Name -notin "internal", "default" }
		}
		
		Write-Output "Migrating pools"
		foreach ($pool in $pools) {
			$poolName = $pool.name
			if ($destserver.ResourceGovernor.ResourcePools[$poolName] -ne $null) {
				if ($force -eq $false) {
					Write-Warning "Pool '$poolName' was skipped because it already exists on $destination"
					Write-Warning "Use -Force to drop and recreate"
					continue
				}
				else {
					if ($Pscmdlet.ShouldProcess($destination, "Attempting to drop $poolName")) {
						Write-Verbose "Pool '$poolName' exists on $destination"
						Write-Verbose "Force specified. Dropping $poolName."
						
						try {
							$destpool = $destserver.ResourceGovernor.ResourcePools[$poolName]
							$workloadgroups = $destpool.WorkloadGroups
							foreach ($workloadgroup in $workloadgroups) {
								$workloadgroup.Drop()
							}
							$destpool.Drop()
							$destserver.ResourceGovernor.Alter()
						}
						catch {
							Write-Exception "Unable to drop: $_  Moving on."
							continue
						}
					}
				}
			}
			
			if ($Pscmdlet.ShouldProcess($destination, "Migrating pool $poolName")) {
				try {
					$sql = $pool.Script() | Out-String
					$sql = $sql -replace [Regex]::Escape("'$source'"), "'$destination'"
					Write-Verbose $sql
					Write-Output "Copying pool $poolName"
					$null = $destserver.ConnectionContext.ExecuteNonQuery($sql)
					
					$workloadgroups = $pool.WorkloadGroups
					foreach ($workloadgroup in $workloadgroups) {
						$workgroupname = $workloadgroup.name
						$sql = $workloadgroup.script() | Out-String
						$sql = $sql -replace [Regex]::Escape("'$source'"), "'$destination'"
						Write-Verbose $sql
						Write-Output "Copying $workgroupname"
						$null = $destserver.ConnectionContext.ExecuteNonQuery($sql)
					}
					
				}
				catch {
					Write-Exception $_
				}
			}
		}
		
		if ($Pscmdlet.ShouldProcess($destination, "Reconfiguring")) {
			if ($destserver.Edition -notmatch 'Enterprise' -and $destserver.Edition -notmatch 'Datacenter' -and $destserver.Edition -notmatch 'Developer') {
				Write-Warning "The resource governor is not available in this edition of SQL Server. You can manipulate resource governor metadata but you will not be able to apply resource governor configuration. Only Enterprise edition of SQL Server supports resource governor."
			}
			else {
				Write-Output "Reconfiguring Resource Governor"
				$sql = "ALTER RESOURCE GOVERNOR RECONFIGURE"
				$null = $destserver.ConnectionContext.ExecuteNonQuery($sql)
			}
		}
		
	}
	end {
		Test-DbaDeprecation -DeprecatedOn "1.0.0" -Silent:$false -Alias Copy-SqlResourceGovernor
	}
}
