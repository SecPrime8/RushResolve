#Created by Naaman Miles


$computer = $env:COMPUTERNAME
$localuserpath = "\\" + $computer + "\c$\users"
$allusers =  Get-ChildItem $localuserpath -ErrorAction SilentlyContinue | ?{$_.Name -NotMatch "(Public|Install|Administrator|ENT*|Default|VDITESTACCT|Ctx_StreamingSvc|RushADM|domainjoin-tc-svc)"}
$Applications = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\_Applications"
        if (!(Test-Path -path $Applications)) {New-Item $Applications -Type Directory}

foreach($user in $allusers){


$Signatures = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Signatures"
if (!(Test-Path -path $Signatures)) {New-Item $Signatures -Type Directory}

$Templates = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Templates"
if (!(Test-Path -path $Templates)) {New-Item $Templates -Type Directory}

$Firefox = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Firefox"
if (!(Test-Path -path $Firefox)) {New-Item $Firefox -Type Directory}

$Profiles = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Firefox\Profiles"
if (!(Test-Path -path $Profiles)) {New-Item $Profiles -Type Directory}

$Chrome = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Chrome"
if (!(Test-Path -path $Chrome)) {New-Item $Chrome -Type Directory}

$Edge = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Edge"
if (!(Test-Path -path $Edge)) {New-Item $Edge -Type Directory}

$StickyNotes = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\StickyNotes"
if (!(Test-Path -path $StickyNotes)) {New-Item $StickyNotes -Type Directory}

$Desktop = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Desktop"
if (!(Test-Path -path $Desktop)) {New-Item $Desktop -Type Directory}

$Documents = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Documents"
if (!(Test-Path -path $Documents)) {New-Item $Documents -Type Directory}

$Downloads = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Downloads"
if (!(Test-Path -path $Downloads)) {New-Item $Downloads -Type Directory}

$Favorites = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Favorites"
if (!(Test-Path -path $Favorites)) {New-Item $Favorites -Type Directory}

$Music = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Music"
if (!(Test-Path -path $Music)) {New-Item $Music -Type Directory}

$Pictures = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Pictures"
if (!(Test-Path -path $Pictures)) {New-Item $Pictures -Type Directory}

$Videos = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Videos"
if (!(Test-Path -path $Videos)) {New-Item $Videos -Type Directory}

$Links = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Links"
if (!(Test-Path -path $Links)) {New-Item $LInks -Type Directory}

$Contacts = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Contacts"
if (!(Test-Path -path $Contacts)) {New-Item $Contacts -Type Directory}

$OneDrive = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\OneDrive - rush.edu"
if (!(Test-Path -path $OneDrive)) {New-Item $OneDrive -Type Directory}




Copy-Item C:\users\$user\Appdata\Roaming\Microsoft\Signatures\ "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item C:\users\$user\Appdata\Roaming\Microsoft\Templates\ "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user"  -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item C:\users\$user\Appdata\Roaming\Mozilla\Firefox\Profiles\ "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Firefox" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item C:\users\$user\Appdata\Roaming\Mozilla\Firefox\installs.ini "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Firefox\Firefoxinstalls.ini" -Force -ErrorAction SilentlyContinue
Copy-Item C:\users\$user\Appdata\Roaming\Mozilla\Firefox\profiles.ini "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Firefox\Firefoxprofiles.ini" -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\Appdata\Roaming\Microsoft\Sticky Notes\StickyNotes.snt" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\StickyNotes\ThresholdNotes.snt" -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState\Legacy\" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\StickyNotes" -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\Appdata\Local\Google\Chrome\User Data\Default\Bookmarks" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Chrome\Bookmarks" -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\Appdata\Local\Microsoft\Edge\User Data\Default\Bookmarks" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user\Edge\Bookmarks" -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\Desktop\" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\Documents\" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\Downloads\" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\Favorites\" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\Music\" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\Pictures\" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\Videos\" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\Links\" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\Contacts\" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "C:\users\$user\OneDrive - rush.edu\" "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\$user" -Recurse -Force -ErrorAction SilentlyContinue


}

        
        #Get all files from C:\windows\installer folder. Exclude folders
        $installerfolder = Get-ChildItem "\\$computer\C$\Windows\Installer"  | ?{$_.Name -like "*.msi"}  | Select Name


            foreach($filename in $installerfolder){
                $filename = $filename.Name
                
                #Variable that contains the complete path of each file in the C:\Windows\Installer folder
                $installerfullpaths = "\\$computer\C$\Windows\Installer\$filename"

                foreach($installerfullpath in $installerfullpaths){
                    
                    #Create a shell to get advanced attributes for each file (Subject)
                    $path = $installerfullpath
                    $shell = New-Object -COMObject Shell.Application
                    $folder = Split-Path $path
                    $file = Split-Path $path -Leaf
                    $shellfolder = $shell.Namespace($folder)
                    $shellfile = $shellfolder.ParseName($file)
                    $ApplicationName = $shellfolder.GetDetailsOf($shellfile, 22)

                    #Create custom object for eventual output to CSV file with three columns (ComputerName, ApplicationName, and FileName)
                    $ApplicationListObjects = @{
                                        
                                        ComputerName = $computer
                                        ApplicationName = $ApplicationName
                                        Filename = $filename
                                        }

                                        $ApplicationList= New-Object psobject -Property $ApplicationListObjects
                                        

                                        
                            
                                        if(!$ApplicationList.ApplicationName -or $ApplicationList.ApplicationName -like "Patch" -or $ApplicationList.ApplicationName -like "*Microsoft*" -or $ApplicationList.ApplicationName -like "Visual*" -or $ApplicationList.ApplicationName -like "Citrix*" -or $ApplicationList.ApplicationName -like "*Webex*" -or $ApplicationList.ApplicationName -like "Adobe*" -or $ApplicationList.ApplicationName -like "Apple*" -or $ApplicationList.ApplicationName -like "Google*" -or $ApplicationList.ApplicationName -like "Tanium Client Installer" -or $ApplicationList.ApplicationName -like "PhishAlarm Outlook Add-In" -or $ApplicationList.ApplicationName -like "Configuration Manager Client" -or $ApplicationList.ApplicationName -like "Quicktime*" -or $ApplicationList.ApplicationName -like "Java*" -or $ApplicationList.ApplicationName -like "Office*" -or $ApplicationList.ApplicationName -like "SQL Server*" -or $ApplicationList.ApplicationName -like "*ReportViewer*" -or $ApplicationList.ApplicationName -like "Local Administrator Password Solution" -or $ApplicationList.ApplicationName -like "Online Plug-in" -or $ApplicationList.ApplicationName -like "Itunes*" -or $ApplicationList.ApplicationName -like "Windows*" -or $ApplicationList.ApplicationName -like "Self-service Plug-in" -or $ApplicationList.ApplicationName -like "Blank Project Template"){}
                                        

                                        elseif($ApplicationList.ApplicationName){
                                        

                                        foreach($ImportedComputer in $ApplicationList){
                                        $ImportedComputerName=$ImportedComputer.ComputerName

                                        #Create variables for ApplicationName from modified CSV
                                        $ImportedApplicationNames = $ImportedComputer.ApplicationName

                                        $ImportedApplicationNames | ForEach-Object{
                                        New-Item -Path "$Applications" -Name "$_" -ItemType "directory" -ErrorAction SilentlyContinue

                                        }


                                        #Create variables for ApplicationName from modified CSV
                                        $ImportedApplicationNames = $ApplicationList.ApplicationName


                                        #Use Filenames from modified csv to initiate a file transfer
                                        $SourcePath = "\\$ImportedComputerName\c$\windows\installer\" + $ImportedComputer.FileName
                                        $DestinationPath = "$Applications\" + $ImportedComputer.ApplicationName
                                        Copy-item $SourcePath $DestinationPath -ErrorAction SilentlyContinue
                                        }}}}   