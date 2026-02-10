#Created by Naaman Miles

$computer = $env:COMPUTERNAME
$user=$env:Username
#$localuserpath = "\\" + $computer + "\c$\users"
#$allusers =  Get-ChildItem $localuserpath -ErrorAction SilentlyContinue | ?{$_.Name -NotMatch "(Public|Install|Administrator|ENT*|Default|VDITESTACCT|Ctx_StreamingSvc|RushADM)"}





$Legacy = "C:\users\$user\AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState\Legacy"
if (!(Test-Path -path $Legacy)) {New-Item $Legacy -Type Directory}

Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Signatures" "C:\users\$user\Appdata\Roaming\Microsoft" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Templates\" "C:\users\$user\Appdata\Roaming\Microsoft" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Firefox\Profiles\" "C:\users\$user\Appdata\Roaming\Mozilla\Firefox" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Firefox\Firefoxinstalls.ini" "C:\users\$user\Appdata\Roaming\Mozilla\Firefox"-Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Firefox\Firefoxprofiles.ini" "C:\users\$user\Appdata\Roaming\Mozilla\Firefox" -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\StickyNotes\ThresholdNotes.snt" "C:\users\$user\AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState\Legacy" -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\StickyNotes\Legacy\" "C:\users\$user\AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Chrome\Bookmarks" "C:\users\$user\Appdata\Local\Google\Chrome\User Data\Default\Bookmarks" -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Edge\Bookmarks" "C:\users\$user\Appdata\Local\Microsoft\Edge\User Data\Default\Bookmarks" -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Desktop\" "C:\users\$user\OneDrive - rush.edu" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Documents\" "C:\users\$user\OneDrive - rush.edu" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Pictures\" "C:\users\$user\OneDrive - rush.edu" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Downloads\" "C:\users\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Favorites\" "C:\users\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Music\" "C:\users\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Videos\" "C:\users\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Links\" "C:\users\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Contacts\" "C:\users\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\OneDrive - rush.edu\" "C:\users\$user" -Recurse -Force -ErrorAction SilentlyContinue