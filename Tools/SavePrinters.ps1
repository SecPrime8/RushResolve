$PrinterFile = "\\rush.edu\vdi\apphub\tools\NetworkPrinters\$env:computername" + " " + $env:username + ".txt"

$Printers = Get-WmiObject -Query " SELECT * FROM Win32_Printer" | Select Name, Default | Where {$_.Name -notlike "*PS201*"}
Remove-Item -Path $PrinterFile -ErrorAction SilentlyContinue

foreach($Printer in $Printers){


if($Printer.Default -eq $False){

Add-Content $PrinterFile -Value $Printer.Name

}


elseif($Printer.Default -eq $True){

Add-Content $PrinterFile -Value ($Printer.Name + "=" + "Default")
}
}

