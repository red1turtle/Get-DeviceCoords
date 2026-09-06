#create the HKU psdrive
New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Global -ErrorAction SilentlyContinue| out-null

try{
    #find user session keys
    $sid_sessions = (ls HKU:\ -ErrorAction Stop | ? {$_.name -match "S-1-5-21-" -and $_.name -notmatch "classes"}).name

    foreach($sid in $sid_sessions){
        #flip the location services nipple to green
        $LocationPath = "HKU:\$($sid)\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"
        Set-ItemProperty -Path $LocationPath -Name Value -Value Allow
    }
}
catch{
    #didn't work
    [pscustomobject]@{
        SID     = $sid
        CanRead = $false
        Value   = $LocationPath
        Allowed = $false
        Error   = $_.Exception.Message
    }
}


Add-Type -AssemblyName System.Device

#create a location service object
$GeoWatcher = New-Object System.Device.Location.GeoCoordinateWatcher
sleep 2

#get the access value for out new geo oject
$allowed = $GeoWatcher.permission.value__

if($allowed -eq 2){ 
    #too bad, I guess you we'rent allowed to enable location services
    "Not Allowed to create a GeoWatcher...`nGAME OVER!"
    break 
}

#if you get here... game on!
$GeoWatcher.Start()
 
write-host "Fetching GeoLocator Coordinates."
$chk = 0
while($GeoWatcher.Position.Location.IsUnknown -and $chk -le 30){
    "waiting for Geowatcher to get an initial position..."|out-string
    sleep -Seconds 2
    $chk++
}

if(($GeoWatcher.Position.Location.Latitude.tostring() -ne "NaN")){
    $lat = $GeoWatcher.Position.Location.Latitude
    $long = $GeoWatcher.Position.Location.Longitude
    #output the first set of coordinates!
    $lat,$long
    'https://www.google.com/maps/search/?api=1&query={0},{1}' -f $lat,$long
}
else{
    "Could not get a GeoWatcher position."
}

#cleanup
$GeoWatcher.Stop()