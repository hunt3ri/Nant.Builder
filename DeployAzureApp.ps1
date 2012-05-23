##############################################################################
#  Author:		 Iain Hunter (@hunt3ri)
#  Date Created: 23/05/12
#  Description:	 Slightly enhanced version of PublishCloudApp.ps1 to make it
#                compatible with Windows Azure PowerShell Cmdlets v2.2.2.
#                Original version can be found here:
#                http://www.windowsazure.com/en-us/develop/net/common-tasks/continuous-delivery/#step4
##############################################################################>


Param(  $serviceName = "",
        $storageAccountName = "",
        $packageLocation = "",
        $cloudConfigLocation = "",
		$thumbprint = "",
		$subscriptionId = "",
        
        $Environment = "Staging",
        $deploymentLabel = "ContinuousDeploy to $servicename",
        $timeStampFormat = "g",
        $alwaysDeleteExistingDeployments = 1,
        $enableDeploymentUpgrade = 1,
        $selectedsubscription = "default",
        $subscriptionDataFile = "c:\scripts\WindowsAzure\Subscription.xml"
     )
      

#initialize cmdlet snapin and subscription
if ((Get-PSSnapin | ?{$_.Name -eq "WAPPSCmdlets"}) -eq $null)
{
  Add-PSSnapin WAPPSCmdlets
}

$cert = Get-Item cert:\CurrentUser\My\$thumbprint 
$subid = $subscriptionId 

#Time to implant your code :-)
set-subscription -subscriptionname inception -certificate $cert -subscriptionid $subid 
select-subscription iain 

$subscription = Get-Subscription inception
$subscriptionname = $subscription.subscriptionname
$subscriptionid = $subscription.subscriptionid
$slot = $environment


function SuspendDeployment()
{
	write-progress -id 1 -activity "Suspending Deployment" -status "In progress"
	Write-Output "$(Get-Date –f $timeStampFormat) - Suspending Deployment: In progress"

	$suspend = Set-DeploymentStatus -Slot $slot -ServiceName $serviceName -Status Suspended
	$opstat = Get-OperationStatus -operationid $suspend.operationId
	
	while ([string]::Equals($opstat, "InProgress"))
	{
		sleep -Seconds 1

		$opstat = Get-OperationStatus -operationid $suspend.operationId
	}

	write-progress -id 1 -activity "Suspending Deployment" -status $opstat
	Write-Output "$(Get-Date –f $timeStampFormat) - Suspending Deployment: $opstat"
}

function DeleteDeployment()
{
	SuspendDeployment

	write-progress -id 2 -activity "Deleting Deployment" -Status "In progress"
	Write-Output "$(Get-Date –f $timeStampFormat) - Deleting Deployment: In progress"

	$removeDeployment = Remove-Deployment -Slot $slot -ServiceName $serviceName
	$opstat = WaitToCompleteNoProgress($removeDeployment.operationId)
	
	write-progress -id 2 -activity "Deleting Deployment" -Status $opstat
	Write-Output "$(Get-Date –f $timeStampFormat) - Deleting Deployment: $opstat"
	
	sleep -Seconds 10
}

function WaitToCompleteNoProgress($operationId)
{
	$result = Get-OperationStatus -OperationId $operationId
	
	while ([string]::Equals($result, "InProgress"))
	{
		sleep -Seconds 1
		$result = Get-OperationStatus -OperationId $operationId
	}
	
	return $result
}

function Publish()
{
	$deployment = Get-Deployment -ServiceName $serviceName -Slot $slot -ErrorVariable a -ErrorAction silentlycontinue 
    if ($a[0] -ne $null)
    {
        write-host "No deployment is detected. Creating a new deployment. "
    }
    #check for existing deployment and then either upgrade, delete + deploy, or cancel according to $alwaysDeleteExistingDeployments and $enableDeploymentUpgrade boolean variables
	if ($deployment.Name -ne $null)
	{
		switch ($alwaysDeleteExistingDeployments)
	    {
	        1 
			{
                switch ($enableDeploymentUpgrade)
                {
                    1
                    {
                        Write-Output "$(Get-Date –f $timeStampFormat) - Deployment exists in $servicename.  Upgrading deployment."
				        UpgradeDeployment
                    }
                    0  #Delete then create new deployment
                    {
                        Write-Output "$(Get-Date –f $timeStampFormat) - Deployment exists in $servicename.  Deleting deployment."
				        DeleteDeployment
                        CreateNewDeployment
                        
                    }
                } # switch ($enableDeploymentUpgrade)
			}
	        0
			{
				Write-Output "$(Get-Date –f $timeStampFormat) - ERROR: Deployment exists in $servicename.  Script execution cancelled."
				exit
			}
	    }
	} else {
            CreateNewDeployment
    }
}

function CreateNewDeployment()
{
	write-progress -id 3 -activity "Creating New Deployment" -Status "In progress"
	Write-Output "$(Get-Date –f $timeStampFormat) - Creating New Deployment: In progress"

	$newdeployment = New-Deployment -Slot $slot -Package $packageLocation -Configuration $cloudConfigLocation -label $deploymentLabel -ServiceName $serviceName -StorageAccountName $storageAccountName
	$opstat = WaitToCompleteNoProgress($newdeployment.operationId)
	
	write-progress -id 3 -activity "Creating New Deployment" -Status $opstat
    
    $completeDeployment = Get-Deployment -ServiceName $serviceName -Slot $slot
    $completeDeploymentID = $completeDeployment.deploymentid
	Write-Output "$(Get-Date –f $timeStampFormat) - Creating New Deployment: $opstat, Deployment ID: $completeDeploymentID"
    
	StartInstances
}

function UpgradeDeployment()
{
	write-progress -id 3 -activity "Upgrading Deployment" -Status "In progress"
	Write-Output "$(Get-Date –f $timeStampFormat) - Upgrading Deployment: In progress"

	Update-Deployment -Slot $slot -Package $packageLocation -Configuration $cloudConfigLocation -label $deploymentLabel -ServiceName $serviceName -StorageAccountName $storageAccountName | 
   Get-OperationStatus -WaitToComplete
    
    #$opstat = WaitToCompleteNoProgress($newdeployment.operationId)
	
	#write-progress -id 3 -activity "Upgrading New Deployment" -Status $opstat
    
    $completeDeployment = Get-Deployment -ServiceName $serviceName -Slot $slot
    $completeDeploymentID = $completeDeployment.deploymentid
	Write-Output "$(Get-Date –f $timeStampFormat) - Upgrading Deployment: Succeeded, Deployment ID: $completeDeploymentID"

}

function StartInstances()
{
	write-progress -id 4 -activity "Starting Instances" -status "In progress"
	Write-Output "$(Get-Date –f $timeStampFormat) - Starting Instances: In progress"

	$run = Set-DeploymentStatus -Slot $slot -ServiceName $serviceName -Status Running
	$deployment = Get-Deployment -ServiceName $serviceName -Slot $slot
	$oldStatusStr = @("") * $deployment.RoleInstanceList.Count
	
	while (-not(AllInstancesRunning($deployment.RoleInstanceList)))
	{
		$i = 1
		foreach ($roleInstance in $deployment.RoleInstanceList)
		{
			$instanceName = $roleInstance.InstanceName
			$instanceStatus = $roleInstance.InstanceStatus

			if ($oldStatusStr[$i - 1] -ne $roleInstance.InstanceStatus)
			{
				$oldStatusStr[$i - 1] = $roleInstance.InstanceStatus
				Write-Output "$(Get-Date –f $timeStampFormat) - Starting Instance '$instanceName': $instanceStatus"
			}

			write-progress -id (4 + $i) -activity "Starting Instance '$instanceName'" -status "$instanceStatus"
			$i = $i + 1
		}

		sleep -Seconds 1

		$deployment = Get-Deployment -ServiceName $serviceName -Slot $slot
	}

	$i = 1
	foreach ($roleInstance in $deployment.RoleInstanceList)
	{
		$instanceName = $roleInstance.InstanceName
		$instanceStatus = $roleInstance.InstanceStatus

		if ($oldStatusStr[$i - 1] -ne $roleInstance.InstanceStatus)
		{
			$oldStatusStr[$i - 1] = $roleInstance.InstanceStatus
			Write-Output "$(Get-Date –f $timeStampFormat) - Starting Instance '$instanceName': $instanceStatus"
		}

		write-progress -id (4 + $i) -activity "Starting Instance '$instanceName'" -status "$instanceStatus"
		$i = $i + 1
	}
	
	$opstat = Get-OperationStatus -operationid $run.operationId
	
	write-progress -id 4 -activity "Starting Instances" -status $opstat
	Write-Output "$(Get-Date –f $timeStampFormat) - Starting Instances: $opstat"
}

function AllInstancesRunning($roleInstanceList)
{
	foreach ($roleInstance in $roleInstanceList)
	{
		if ($roleInstance.InstanceStatus -ne "Ready")
		{
			return $false
		}
	}
	
	return $true
}


Write-Output "$(Get-Date –f $timeStampFormat) - Azure Cloud App deploy script started."
Write-Output "$(Get-Date –f $timeStampFormat) - Preparing deployment of $deploymentLabel for $subscriptionname with Subscription ID $subscriptionid."

Publish

$deployment = Get-Deployment -slot $slot -serviceName $servicename
$deploymentUrl = $deployment.Url

Write-Output "$(Get-Date –f $timeStampFormat) - Created Cloud App with URL $deploymentUrl."
Write-Output "$(Get-Date –f $timeStampFormat) - Azure Cloud App deploy script finished."