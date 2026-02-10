$desktopitems=(get-childitem "C:\users\$env:username\OneDrive - rush.edu\Desktop" -recurse).Name
$defaulticons=@("Epic Production","Epic Classic Production","Google Chrome","Link","Microsoft Teams","OneSource Docs","Provider Privilege Access","Webex","Microsoft Edge","Faculty Mgmt System","Work - Edge","Instrument Manager")

cmd.exe /c "C:\Program Files (x86)\Citrix\ICA Client\SelfServicePlugin\SelfService.exe" -rmPrograms

$epic="Epic Enterprise Production.lnk"
$provider="Provider Privilege Access.lnk"
$link="Link.lnk"

remove-item "C:\users\$env:username\Onedrive - rush.edu\Desktop\$epic" -Force
remove-item "C:\users\$env:username\Onedrive - rush.edu\Desktop\$provider" -Force
remove-item "C:\users\$env:username\Onedrive - rush.edu\Desktop\$link" -Force

foreach ($desktopitem in $desktopitems){



foreach($defaulticon in $defaulticons){



if ($desktopitem -like "*$defaulticon*"){

$similaritems=$desktopitem


foreach($similaritem in $similaritems){
   $defaulticon = "$defaulticon" + ".lnk"

        if($similaritem -notmatch $defaulticon){

        remove-item "C:\users\$env:username\Onedrive - rush.edu\Desktop\$similaritem" -Force

}}}}}


cmd /c "C:\Program Files (x86)\Citrix\ICA Client\SelfServicePlugin\SelfService.exe" -poll