$computer = $env:COMPUTERNAME
$Applications = "\\rush.edu\applications\Win10Project\BackupUserData\$env:computername\_Applications"
        if (!(Test-Path -path $Applications)) {New-Item $Applications -Type Directory}
        
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