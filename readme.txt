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

IMPORTANT:		
  a) The script should be run with sudo/admin privaleges, so as to ensure proper execution at all times.
  b) As part of the incremental backup schema, the following file-directory structure is critical:
	1. /path/to/script/backup-info
		- a 'backup-info' directory at the same path as where this script resides, with rwx access to sudo user
			> this directory preserves the means by which track of incremental backups are kept;
				>> temporary time*.txt files are created automatically so as to keep track of previous and current file backups.
				   They may be deleted when the program is not running.
			> this directory preserves the means by which important log files are stored and processed.
			> this directory is created automatically, and it (or its content) my be deleted when the program is not running.

	2. /path/to/script/files
		- a 'files' directory at the same path as where this script resides, with rwx access to sudo user
			> this directory contains programs/scripts critical to the function of the backup script.

INSTRUCTIONS
1. create a directory to house all files, eg. ~/full-backup
2. copy all files into directory in (1)
3. list all the directories (or files) to backup in ./toBackup.txt (full paths only)
4. configure backup parameters in ./full-backup.conf (follow comments for guidance)
5. optional: add files/directories to exclude from backup in ./backup_exclude_list.txt
6. optional: automate backups with crontab
7. ensure all requirements (see below) has been fulfilled.
8. execute backup by running the *.sh file either manually or as crontab scheduled task

REQUIREMENTS:  System software: 
*OPTIONAL: A local, send-only SMTP server (e.g. Postfix) - no dedicated email or 3rd party SMTP server is required Postfix configured to forward all 
system-generated email sent to root, to skyqode@gmail.com (see documentation or https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-postfix-as-a-send-only-smtp-server-on-ubuntu-14-04) b) Rsync c) SSH - with hosts configured for RSA public/private key pair