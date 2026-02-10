$computer = $env:COMPUTERNAME
$ApplicationPath = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\_Applications"
$Applications = Get-childitem "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\_Applications"

Foreach($Application in $Applications){
$Application = $Application.Name
Copy-item "$ApplicationPath\$Application" "C:\Temp\_Restored Applications" -Recurse -Force
}