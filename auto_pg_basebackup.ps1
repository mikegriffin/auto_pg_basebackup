############################################################################################################################################
######
###### Name: auto_pg_basebackup.ps1
###### Assets: auto_pg_basebackup.ps1 auto_pg_basebackup.xml LICENSE README
<#
  .SYNOPSIS
  Script to automate pg_basebackup, via Windows Task Scheduler or pgAgent

  .DESCRIPTION
  First, optionally delete old backups, then create a PostgreSQL backup, and finally log any failure.
  Runs every 8 hours by default, when using the supplied auto_pg_basebackup.xml

  Registry permissions required to use $CREATEFAILUREEVENT for failures (New-EventLog, Write-EventLog)

  Credentials to be used by the script will need to be stored in: %APPDATA%\postgresql\pgpass.conf

  The path of pgpass.conf will vary, depending on who invokes the script, eg for taskschd.msc running as "SYSTEM" (UserId S-1-5-18):
   mkdir C:\Windows\System32\config\systemprofile\AppData\Roaming\postgresql
   notepad C:\Windows\System32\config\systemprofile\AppData\Roaming\postgresql\pgpass.conf

  For pg_basebackup, use a wildcard in the datname field of pgpass.conf such as:
   localhost:5432:*:postgres:p@ssw0rd

  To keep credential files in sync between Windows admin accounts, create a symlink dir in cmd.exe for your login to share, eg:
   mklink /d %APPDATA%\postgresql C:\Windows\System32\config\systemprofile\AppData\Roaming\postgresql

  If you are creating the symlink dir in PowerShell instead of cmd.exe use something like:
   New-Item -Path $env:APPDATA\postgresql -ItemType SymbolicLink -Value C:\Windows\System32\config\systemprofile\AppData\Roaming\postgresql

  .INPUTS
  None. You can't pipe objects to auto_pg_basebackup.ps1.

  .OUTPUTS
  Usually none. auto_pg_basebackup.ps1 should generate any output, unless it can't write to the backup directory.

  .EXAMPLE
  # schedule the task using the supplied xml file
   schtasks.exe /create /xml auto_pg_basebackup.xml /tn auto_pg_basebackup
  
  .NOTES
  Version:        0.9.94
  Link:           https://github.com/mikegriffin/auto_pg_basebackup/
#>


############################################################################################################################################
# Configuration section begin
############################################################################################################################################

# Adjust this path for installation of PostgreSQL
$env:Path += ';C:\Program Files\PostgreSQL\16\bin'

# Set the drive letter to store backups on, without any colon or slash
$BACKUPDRIVE="C"
# Set the directory under this drive
$BACKUPDIR="PGbackup"

# Boolean on whether this script should delete older backups or not
$DELETEOLDBACKUPS=1
# Number of hours ago a backup should be, to be considered old
$DELETEOLDBACKUPSHOURS=36

# A file called backup_succeeded is always deleted at the start of a backup run and may be created afterward
# The file backups_failed.log is never deleted and its existance is evidence of one or more failures
# On error, create or append to a file backups_failed.log
$CREATEFAILURELOG=1

# And/or send an Event to Application log as source auto_pg_basebackup
# Behavior of this script when $CREATEFAILUREEVENT=1 and permissions are lacking is untested
$CREATEFAILUREEVENT=1


############################################################################################################################################
# Script begin
############################################################################################################################################

# Create the backup directory on the target drive and test permissions
$FQBACKUPDIR = $BACKUPDRIVE,$BACKUPDIR -join ":\"
if (-not(Test-Path -Path $FQBACKUPDIR)) {
New-Item -ItemType "directory" -Path $FQBACKUPDIR | Out-Null
}
Try {[io.file]::OpenWrite("$FQBACKUPDIR\test").close()}
 Catch {
     $CURRENTUSER=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
     Write-Error "$CURRENTUSER unable to write to $FQBACKUPDIR\test" -ErrorAction Stop
}
if (Test-Path -Path $FQBACKUPDIR\test) {
    Remove-Item -Path $FQBACKUPDIR\test
}


# Generate a unique name for the backup
$CURRENTBACKUP = (Get-Date).ToString("yyyyMMdd_HHmmssfff"),"backup" -join "."
$FQCURRENTBACKUP = $FQBACKUPDIR,$CURRENTBACKUP -join "\"


Function Launch-ActualPgBaseBackup {
    $PGBASEBACKUPARGS = "--username=postgres",
                        "--no-password",
                        "--checkpoint=fast",
                        "--format=tar",
                        "--wal-method=stream",
                        "--compress=server-zstd:3",
                        "--pgdata=$FQCURRENTBACKUP"
    # Launch pg_basebackup
    $error.clear()
    &pg_basebackup $PGBASEBACKUPARGS 2>&1 | Out-File $LOGFILE
}


Function Delete-EmptyFolder($path)
{
    ### Delete empty folders and folders with only hidden files, unless the folder was created too recently
    ### https://lazyadmin.nl/it/remove-empty-directories-with-powershell/

    # Go through each subfolder,
    Foreach ($subFolder in Get-ChildItem -Force -Literal $path -Directory)
    {
        # Call the function recursively
        Delete-EmptyFolder -path $subFolder.FullName
    }

    # Get all child items
    $subItems = Get-ChildItem -LiteralPath $path

    # If there are no items, then we can delete the folder
    # Exclude folder: If (($subItems -eq $null) -and (-Not($path.contains("DfsrPrivate"))))
    If ($subItems -eq $null)
    {
        # Exclude empty folders which were created too recently
        If (Get-Item -LiteralPath $Path | Where-Object {($_.CreationTime -lt (Get-Date).AddSeconds(-600))})
        {
            # Delete the folder
            Remove-Item -Force -Recurse -LiteralPath $Path
        }
    }
}


Function Run-PGBasebackup {
    # Define a logfile for the current backup in the top-level directory, later copy into backup, and rename to backup_succeeded
    $LOGFILE = $FQBACKUPDIR,"$($CURRENTBACKUP).in-progress.log" -join "\"

    # Remove any existing backup_succeeded
    if (Test-Path -Path "$FQBACKUPDIR\backup_succeeded") {
        Remove-Item -Path "$FQBACKUPDIR\backup_succeeded"
    }

    Launch-ActualPgBaseBackup

    if ($error.count -eq 0) {
        Copy-Item $LOGFILE -Destination $FQBACKUPDIR'\'$CURRENTBACKUP'\log.log'
        # Rename-Item can't overwrite existing file, such as when two backups are running, which is probably rare
        Move-Item -Force -Path $LOGFILE -Destination $FQBACKUPDIR"\backup_succeeded"
     }
    else {
        # Save log file as -failed.log, these are eventually deleted by $DELETEOLDBACKUPS
        Rename-Item -Path $LOGFILE -NewName "$($CURRENTBACKUP).failed.log"

        if ($CREATEFAILURELOG -eq 1) {
            if (Test-Path -Path "$FQBACKUPDIR\backups_failed.log") {    
                "[FAIL] $CURRENTBACKUP" | Out-File -FilePath "$FQBACKUPDIR\backups_failed.log" -Append
            }
            else {
                New-Item -Path $FQBACKUPDIR -Name "backups_failed.log" -ItemType File | Out-Null
                "############################################" | Out-File -FilePath "$FQBACKUPDIR\backups_failed.log" -Append
                "## This file is not automatically removed ##" | Out-File -FilePath "$FQBACKUPDIR\backups_failed.log" -Append
                "############################################" | Out-File -FilePath "$FQBACKUPDIR\backups_failed.log" -Append
                "[FAIL] $CURRENTBACKUP" | Out-File -FilePath "$FQBACKUPDIR\backups_failed.log" -Append
            }
        }

        if ($CREATEFAILUREEVENT -eq 1) {
            if (-not([System.Diagnostics.EventLog]::SourceExists("auto_pg_basebackup"))) {
                    New-EventLog -LogName Application -Source "auto_pg_basebackup" 2>&1 | Out-Null
            }
            $EventLogMessage="PostgreSQL Backup Failure detected in $FQCURRENTBACKUP by $PSCommandPath"
            Write-EventLog -LogName Application -Source "auto_pg_basebackup" -EntryType Error -Category 0 -EventId 500 -Message $EventLogMessage 2>&1 | Out-Null
        }
    }
}




if ($DELETEOLDBACKUPS -eq 1) {
    Get-ChildItem -Path $FQBACKUPDIR -File -Recurse -Force | 
        Where-Object {($_.LastWriteTime -lt (Get-Date).AddHours(-$DELETEOLDBACKUPSHOURS)) -and (-not($_.Name -contains 'backups_failed.log'))} |
        Remove-Item -Force

    # Make a temporary file mostly to ensure that $FQBACKUPDIR itself has a recent file in it
    $DeletingOldFiles = $CURRENTBACKUP,"DeleteFilesInProgress","log" -join "."
    New-Item -Path $FQBACKUPDIR -ItemType "file" -Name $DeletingOldFiles | Out-Null
    Delete-EmptyFolder -path $FQBACKUPDIR
    Remove-Item $FQBACKUPDIR"\"$DeletingOldFiles

}


# Run the backup
Run-PGBasebackup 
