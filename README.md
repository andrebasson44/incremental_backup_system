# incremental_backup_system

PROGRAM:  Full Backup System
AUTHOR: Andre Basson

DESCRIPTION: 
An INCREMENTAL (snapshot) backup script, which syncs data - files and directories listed in ./toBackup.txt - either 
between a remote and local host, local to local host, or local to remote host.  ONLY in the first scenario is data 
PULLed from the remote host (as opposed to the remote host instigating the transfer by PUSHing the data).  
The other two scenarios syncs by PUSHing the data.

This Incremental backup method utilises RSYNC with hardlinks, and preserves directory structure (ie. creates exact 
directory structure on the fly).

Counter to the full backup system (available elsewhere), this version is modifed to sync one full image and its historical increments
between two hosts, and over SSH connection if either is located remotely.  

Snapshot backups are nothing more than incremental backups, but they utilize hardlinks to retain the file structure 
of the original source. The script below - when called as a cronjob, say, every 2 hours - will automatically backup
your data at regular intervals.  Every backup will be stored under unique month-day-year-time named directories, and will
preserve the original directory structure.  

Take care in noting that some client OS's might not be able to read some characters used in the output files used.  
If, for instance, you'll be sharing those files via Samba, you will likely have to include the catvfs module in its config file:
	eg. add these two lines:                  
            	vfs objects = catia
		catia:mappings = 0x22:0xa8,0x2a:0xa4,0x2f:0xf8,0x3a:0xf7,0x3c:0xab,0x3e:0xbb,0x3f:0xbf,0x5c:0xff,0x7c:0xa6

When traversing any of the backup directories, you’d see every file from the source directory exactly as it was at that time.
Yet, there would be no duplicates across any two directories.  Rsync accomplishes this with the use of hardlinking through the
 --link-dest=DIR argument.
 
See readme.txt for INSTRUCTIONS, REQUIREMENTS and IMPORTANT notes.
