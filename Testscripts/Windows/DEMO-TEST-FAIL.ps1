﻿# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
$CurrentTestResult = CreateTestResultObject
$resultArr = @()

$isDeployed = "THIS-IS-DEMO-FAIL"
if ($isDeployed)
{
	try
	{
        LogMsg "Test Result : FAIL."
        $testResult = "FAIL"
	}
	catch
	{
		$ErrorMessage =  $_.Exception.Message
		LogMsg "EXCEPTION : $ErrorMessage"
	}
	Finally
	{
		if (!$testResult)
		{
			$testResult = "Aborted"
		}
		$resultArr += $testResult
	}
}

else
{
	$testResult = "FAIL"
	$resultArr += $testResult
}

$CurrentTestResult.TestResult = GetFinalResultHeader -resultarr $resultArr

#Clean up the setup
DoTestCleanUp -CurrentTestResult $CurrentTestResult -testName $currentTestData.testName -ResourceGroups $isDeployed

#Return the result and summery to the test suite script..
return $CurrentTestResult
