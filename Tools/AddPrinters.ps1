$PrinterDirectory = "\\rush.edu\vdi\apphub\tools\NetworkPrinters"
Set-Location $PrinterDirectory
$FilenameWithUsername = @(New-Object PSObject -Property @{Name = $env:computername + " " + $env:username + ".txt"})
$FilenamewithUsernamePath = $PrinterDirectory + "\" + $FilenameWithUsername.Name
$FilenamewithUsernameTest = Test-Path -Path $FilenamewithUsernamePath
$Filename = @(New-Object PSObject -Property @{Name = $env:computername + ".txt"})
$PrinterDirectoryListing=@(Get-ChildItem -Recurse -Path $PrinterDirectory | Select Name)

    
    
    if($FilenamewithUsernameTest -eq "True"){ 
  
        
        Foreach($Printerlisting in $PrinterDirectoryListing){
  
        
        $results=Compare-Object $FilenameWithUsername $Printerlisting -IncludeEqual -Property Name
  
 
        Foreach($R in $results){
                
                
                
            if($R.sideindicator -eq "=="){ 
                        
                        
                        
                $Printercontent = get-content $R.Name | Select-String -Pattern "\\RUDWV-PS401"
  
                        
                                
                    foreach($printer in $Printercontent){
 
                                        

                        if($printer -like "*Default*"){
                                        
                        $printer=$printer -replace "=Default"
                        Add-Printer -ConnectionName $printer
                        (New-Object -ComObject WScript.Network).SetDefaultPrinter($printer)
                
                        }
                
                                        
                                        
                        elseif($printer -notlike "*Default*"){ 
                                        
                        Add-Printer -ConnectionName $printer
                
                        }
                        }
                        }

 
 
                 
}}}


    else{

                    
        Foreach($Printerlisting in $PrinterDirectoryListing){

        $results2=Compare-Object $Filename $Printerlisting -IncludeEqual -Property Name
    
        Foreach($R2 in $results2){
                                    
                                  

            if($R2.sideindicator -eq "=="){
                
                                        
                                        
                $Printercontent2 = get-content $R2.Name | Select-String -Pattern "\\RUDWV-PS401"    
                                        
 
                    foreach($printer2 in $Printercontent2){
 
                

                        if($printer2 -like "*Default*"){
                                        

                        $printer2=$printer2 -replace "=Default"
                        Add-Printer -ConnectionName $printer2
                        (New-Object -ComObject WScript.Network).SetDefaultPrinter($printer2)

                        }
                
                                        
                                        
                        elseif($printer2 -notlike "*Default*"){ 
                                        
                        Add-Printer -ConnectionName $printer2
            
                        }         
                        }
                        }
                        }
}}

