# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
<#
.Synopsis
 Verify that demand changes with memory pressure inside the VM.

 Description:
   The Scripts installs the Stress App and generates demand Pressure. Verify that demand changes with memory pressure inside the VM.

   Only 1 VM is required for this test.

   The testParams have the format of:

      vmName=Name of a VM, enable=[yes|no], minMem= (decimal) [MB|GB|%], maxMem=(decimal) [MB|GB|%],
      startupMem=(decimal) [MB|GB|%], memWeight=(0 < decimal < 100)
#>

param([string] $TestParams)
# we need a scriptblock in order to pass the function to start-job
# The script block is not part of the common function, so the script block is present here
$scriptBlock = {
   function ConsumeMemory([String]$WorkingDirectory, [String]$VMIpv4, [String]$VMSSHPort, [int]$timeoutStress, [String]$user, [String]$password)
   {
        Set-Location $WorkingDirectory
        $cmdToVM = @"
#!/bin/bash
        if [ ! -e /proc/meminfo ]; then
            echo ConsumeMemory: no meminfo found. Make sure /proc is mounted >> /root/HotAdd.log 2>&1
            exit 100
        fi
        rm ~/HotAddErrors.log -f
        __totalMem=`$(cat /proc/meminfo | grep -i MemTotal | awk '{ print `$2 }')
        __totalMem=`$((__totalMem/1024))
        echo ConsumeMemory: Total Memory found `$__totalMem MB >> HotAdd.log 2>&1
        __chunks=128
        __duration=280
        __iterations=28
        echo "Going to start `$__iterations instance(s) of stresstestapp with a __duration of `$__duration and a timeout of $timeoutStress each consuming 128MB memory" >> HotAdd.log 2>&1
        for ((i=0; i < `$__iterations; i++)); do
            /usr/local/bin/stressapptest -M `$__chunks -s `$__duration &
            __duration=`$((`$__duration - 10))
            sleep $timeoutStress
        done
        echo "Waiting for jobs to finish" >> HotAdd.log 2>&1
        wait
        exit 0
"@
        # sendig command to vm: $cmdToVM"
        $FILE_NAME = "ConsumeMem.sh"
        Set-Content $FILE_NAME "$cmdToVM"
        # Remote copy did not work in Script block so pscp tool is to send file
        .\Tools\pscp.exe -pw ${password} -P ${VMSSHPort} ${FILE_NAME} $user@${VMIpv4}:
        if ([string]::Compare($leaveTrail, "yes", $true) -ne 0) {
            Remove-Item ".\${FILE_NAME}"
        }
        # The RunLinuxCmd did not work on Scrip block so plink is used to execute the command
        $command = "echo $password | chmod u+x ${FILE_NAME} && sed -i 's/\r//g' ${FILE_NAME} && ./${FILE_NAME}"
        .\tools\plink.exe -t -pw $password -P $VMSSHPort $user@$VMIpv4 $command
        return $retVal
   }
}

#######################################################################
#
# Main script body
#
#######################################################################

function Main {
    param (
        $TestParams
    )
    $currentTestResult = CreateTestResultObject
    $resultArr = @()
    try {
        $testResult = $null
        $captureVMData = $allVMData
        $VMName = $captureVMData.RoleName
        $HvServer= $captureVMData.HyperVhost
        $Ipv4 = $captureVMData.PublicIP
        $VMPort= $captureVMData.SSHPort
        if ($null -eq $vmName) {
            Throw "VM name is null"
        }
        if ($null -eq $HvServer) {
            Throw "hvServer is null"
        }
        if ($null -eq $testParams) {
            Throw "testParams is null"
        }
        # Write out test Params
        $TestParams
        # Name of first VM
        $vm1Name = $vmName
        # number of tries
        # default number of tries
        Set-Variable defaultTries -option Constant -value 3
        # change working directory to root dir
        Set-Location $WorkingDirectory
        if (-not $WorkingDirectory) {
            Throw "INFO : Mandatory param RootDir=Path; not found!"
        }
        $appGitURL = $TestParams.appGitURL
        $summaryLog = "${vmName}_summary.log"
        Remove-Item $summaryLog -ErrorAction SilentlyContinue
        $vm1 = Get-VM -Name $vm1Name -ComputerName $hvServer -ErrorAction SilentlyContinue
        if (-not $vm1) {
            Throw "VM $vm1Name does not exist" | Tee-Object -Append -file $summaryLog
        }
        LogMsg "Checking if Stressapptest is installed"
        $retVal = Publish-App "stressapptest" $Ipv4 $appGitURL $appGitTag $VMPort
        if (-not $retVal) {
            Throw "Stressapptest is not installed! Please install it before running the memory stress tests." | Tee-Object -Append -file $summaryLog
        }
        LogMsg "Stressapptest is installed! Will begin running memory stress tests shortly."
        $timeoutStress = 10
        # get memory stats from vm1
        # wait up to 2 min for it
        Start-Sleep -s 30
        $sleepPeriod = 120 #seconds
        # get VM1 and VM2's Memory
        while ($sleepPeriod -gt 0)
        {
            [int64]$vm1BeforeAssigned = ($vm1.MemoryAssigned/1MB)
            [int64]$vm1BeforeDemand = ($vm1.MemoryDemand/1MB)
            if ($vm1BeforeAssigned -gt 0 -and $vm1BeforeDemand -gt 0) {
                break
            }
            $sleepPeriod-= 5
            Start-Sleep -s 5
        }
        if (($vm1BeforeAssigned -le 0) -or ($vm1BeforeDemand -le 0)) {
            $testResult = $resultFail
            Throw "vm1 $vm1Name reported 0 memory (assigned or demand)." | Tee-Object -Append -file $summaryLog
        }
        LogMsg "  ${vm1Name}: assigned - $vm1BeforeAssigned | demand - $vm1BeforeDemand"
        # Send Command to consume
        $job1 = Start-Job -ScriptBlock { param($WorkingDirectory,$Ipv4,$VMPort,$timeoutStress,$user,$password ) ConsumeMemory $WorkingDirectory $Ipv4 $VMPort $timeoutStress $user $password } -InitializationScript $scriptBlock -ArgumentList($WorkingDirectory,$Ipv4, $VMPort,$timeoutStress,$user,$password)
        if (-not $?) {
            $testResult = $resultFail
            Throw "Unable to start job for creating pressure on $vm1Name" | Tee-Object -Append -file $summaryLog
        }
        # sleep a few seconds so stresstestapp processes start and the memory assigned/demand gets updated
        Start-Sleep -s 100
        # get memory stats for vm1 after stresstestapp starts
        [int64]$vm1Assigned = ($vm1.MemoryAssigned/1MB)
        [int64]$vm1Demand = ($vm1.MemoryDemand/1MB)
        LogMsg "Memory stats after $vm1Name started stresstestapp"
        LogMsg "${vm1Name}: assigned - $vm1Assigned | demand - $vm1Demand"
        LogMsg "vm1BeforeDemand value $vm1BeforeDemand"
        if ($vm1Demand -le $vm1BeforeDemand) {
            Throw "Memory Demand did not increase after starting stresstestapp" | Tee-Object -Append -file $summaryLog
        }
        # Wait for jobs to finish now and make sure they exited successfully
        $timeout = 240
        $firstJobStatus = $false
        while ($timeout -gt 0)
        {
            if ($job1.Status -like "Completed") {
                $firstJobStatus = $true
                $retVal = Receive-Job $job1
                if (-not $retVal[-1]) {
                    Throw "Consume Memory script returned false on VM1 $vm1Name" | Tee-Object -Append -file $summaryLog
                }
                $diff = $totalTimeout - $timeout
                LogMsg "Job finished in $diff seconds."
            }
            if ($firstJobStatus) {
                break
            }
            $timeout -= 1
            Start-Sleep -s 1
        }
        # Verify if errors occured on guest
        $isAlive = Wait-ForVMToStartKVP $vm1Name $hvServer 10
        if (-not $isAlive){
            Throw "VM is unresponsive after running the memory stress test" | Tee-Object -Append -file $summaryLog
        }
        Start-Sleep -s 20
        # get memory stats after stresstestapp finished
        [int64]$vm1AfterAssigned = ($vm1.MemoryAssigned/1MB)
        [int64]$vm1AfterDemand = ($vm1.MemoryDemand/1MB)
        LogMsg "Memory stats after stresstestapp finished: "
        LogMsg "  ${vm1Name}: assigned - $vm1AfterAssigned | demand - $vm1AfterDemand"
        if ($vm1AfterDemand -ge $vm1Demand) {
            $testResult = $resultFail
            Throw "Demand did not go down after stresstestapp finished." | Tee-Object -Append -file $summaryLog
        }
        LogMsg "Memory Hot Add (using stressapptest) completed successfully!"
        $testResult = $resultPass
    }
    catch {
        $ErrorMessage =  $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        LogErr "$ErrorMessage at line: $ErrorLine"
    }
    finally {
        if (!$testResult) {
            $testResult = "ABORTED"
        }
        $resultArr += $testResult
    }
        $currentTestResult.TestResult = GetFinalResultHeader -resultarr $resultArr
        return $currentTestResult.TestResult
}

Main -TestParams (ConvertFrom-StringData $TestParams.Replace(";","`n"))
