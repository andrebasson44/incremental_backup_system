#!/bin/bash
 #
##OVERVIEW:
 #========
 #DESCRIPTION:  An INCREMENTAL (snapshot) backup script, which syncs data - files and directories listed in ./toBackup.txt - either 
  #             between a remote and local host, local to local host, or local to remote host.  ONLY in the first scenario is data 
  #             PULLed from the remote host (as opposed to the remote host instigating the transfer by PUSHing the data).  The other 
  #             two scenarios syncs by PUSHing the data.
  #
  #				      This Incremental backup method utilises RSYNC with hardlinks, and preserves directory structure 
  #				      (ie. creates exact directory structure on the fly).
  #
  #             The method is based on an Rsync Date-Stamped, Snapshot Style, INCREMENTAL Backup strategy 
  #             available at https://www.howtogeek.com/175008/the-non-beginners-guide-to-syncing-data-with-rsync/
  #             This version is modifed to sync one full image and its historical increments
  #             between two hosts, and over SSH connection if either is located remotely.
  #
  #             Snapshot backups are nothing more than incremental backups, but they utilize hardlinks
  #             to retain the file structure of the original source. The script below - when called
  #             as a cronjob, say, every 2 hours - will automatically backup your data every 2 hours.  Every
  #             backup will be stored under unique month-day-year-time named directories, and will
  #             preserve the original directory structure.  
  #  
  #             Take care in noting that some client OS's might not be able to read some characters used in the output files
  #             used.  If, for instance, you'll be sharing those files via Samba, you will likely have to include the catvfs module.
  #             eg. add these two lines:                  
  #                         vfs objects = catia
  #                         catia:mappings = 0x22:0xa8,0x2a:0xa4,0x2f:0xf8,0x3a:0xf7,0x3c:0xab,0x3e:0xbb,0x3f:0xbf,0x5c:0xff,0x7c:0xa6
  #  
  #             When traversing any of the backup directories, you’d see every file from the source
  #             directory exactly as it was at that time.  Yet, there would be no duplicates across
  #             any two directories.  rsync accomplishes this with the use of hardlinking through the
  #             --link-dest=DIR argument.
 #
 #IMPORTANT:		
  #			a) The script should be run with sudo/admin privaleges, so as to ensure proper execution at all times.
  #
  #			b) As part of the incremental backup schema, the following file-directory structure is critical:
  #				1. /path/to/script/backup-info
  #					- a 'backup-info' directory at the same path as where this script resides, with rwx access to sudo user
  #							> this directory preserves the means by which track of incremental backups are kept;
  #							  	>> the time*.txt files within should not be altered in any way. Failing to do
  #								   so will cause the script to recreate a full backup instead (rather than incremental
  #								   from the previous (incremental) backup).
  #				2. /path/to/script/files
  #					- a 'files' directory at the same path as where this script resides, with rwx access to sudo user
  #							> this directory must contain scripts: fileExist.sh, getAddr.sh, and getRsyncPID.sh
  #							  which are critical to the functions of this script.
 #
 #REVISIONs:		Based on incremental-backup_PUSH-and-PULL-version_v1.287.sh
  #             v1.32   - OVERALL STATUS: works pretty well! 
  #                     - CHANGES:  moved code that initializes log files to start of CODE section
  #
  #             V1.31   - OVERALL STATUS: WORKS PRETTY GOOD! (2 issues uncovered from v1.3)
  #                     - ISSUES:  v1.3 issues fixed!!
  #                          1. the 'running...' file isn't wiped when the program SELF-terminate on errors
  #                               > POSSIBLE SOLUTION:  when/where you have 'exit' lines to self-terminate; first clear the 'running...' flag.
  #                                 >> SOLUTION WORKED!!!
  #
  #                          2. time_now.txt from a previous backup attempt INCORRECTLY assumes that the previous increment was ALWAYS succesful.
  #                             When on a failed (non) backup, the new instance then overwrites time_before.txt with the previous time_now.txt time
  #                             that points to a backup directory that doesn't exist; hence resulting in a full backup being made a new (--link-dest points to nothing).
  #                               > POSSIBLE SOLUTION:  write code that retrieves the name (a time stamp) of the latest backup on the target host; then write this
  #                                     directory (time-stamp) to the time_before.txt file.
  #                                 >> SOLUTION WORKED!!!
  #
  #                          3. elementIn () ammended - line 'exit 1' replaced with 'return 1'
  #
  #             v1.3    - OVERALL STATUS: WORKS VERY WELL, INCL. ISSUE v1.285 HAS NOW BEEN FIXED.
  #                          1. Also updated function elementIn ()
  #                          2. No longer interested in persuing to check for concurrency by premise of command [ps -afx]
  #                              Instead introduced a flag mechanism to indicate (with relative accuracy) whether a script is running or not.
  #
  #                              The general mechanism works as follows:
  #                              --------------------------------------
  #                              At the start of the script, the script will look for the existence of a (eg.) 'running...' file at the same
  #                              path as the script executable.  This way no two scripts (at different paths) can be confused with one another.
  #                              If the file exists, it is taken as relative proof that a previous instance of this exact script has not completed
  #                              running.
  #                              If the file doesn't exist, it is taken as relative proof that no previous instance is running at the moment. The 
  #                              script can now create the file (eg. 'running...' ) when it starts, and remove it just before termination.
  #
  #                              The script also utilizes TRAPs (event handlers for catching signals sent to/from scripts) to perform housekeeping
  #                              in case of the script terminating due to EXITing (EXIT command), being Hung UP (1/SIGHUP), being INTerrupted (2/SIGINT),
  #                              being QUITed (3/Ctrl+C/SIGQUIT), being TERMinated (15/SIGTERM), or terminal-stopped (20/SIGTSTP).  Naturally,
  #                              the only housekeeping tasks performed would be to make sure that in case of any of these events occuring, the trap 
  #                              will trigger and ensure that the file will be removed prior to termination.  In most cases this should minimize a 
  #                              false-positive of having the file exist, while the script is actually not running.
  #
  #                              If a false-positive does occur, then it is up to user to confirm if another instance is currently active, and then
  #                              decide if the script should be terminated if active or not.
  #                              Mostlikely the following command (with variant switches) will serve userful:
  #                                  ps -afx -o pid,cmd | grep -Ei "script-name-here" | grep -Evi "(color|watch|grep)"
  #
  #                              Ofcourse, if no script is active (or has been killed), it is up to the user to delete the 'running...' file, BEFORE
  #                              starting another instance.
  # 
  #
  #              v1.288  - OVERALL STATUS: WORKS VERY WELL, WITH v1.285 ISSUES REMAINING.
  #                          1.  Introduction of:
  #                              1.1 MAX_NUM_INCREMENTALS entry to config file (./backup.conf) with which to populate to variable in the script.
  #
  #                        ISSUES REMAINING:
  #                          1.  v1.285 issue remains (see below)
  #
  #              v1.287  - OVERALL STATUS: WORKS VERY WELL, WITH v1.285 ISSUES REMAINING.
  #                          1.  v1.285 issue remains (see below)
  #                          2.  v1.287 introductions (confirmed working 100%):
  #                              2.1 Major changes to convert this script into *both* PUSH and PULL versions, where the addresses of the source
  #                                  and target hosts determine whether data is PUSHed from a local host, or PULLed from a remote host. 
  #                              2.2 Incorporating backup from list (./toBackup.txt) instead of single location only.
  #                              2.3 Confirmed working:
  #                                  - local source to local target:   seems to work 100% (incremental backup to correct location, logs transfered correctly)
  #                                  - remote source to local target:  seems to work 100% (incremental backup to correct location, logs transfered correctly)
  #                                  - local source to remote target:  seems to work 100% (incremental backup to correct location, logs transfered correctly)
  #
  #                          3. Introduced variable SERVER_IP:  future version to replace references to string "localhost" with "$SERVER_IP"
  #                          
  #
  #              v1.285  - OVERALL STATUS: working progress to coincide with the working-release in 'full_backup_PULL-version_V1.285.sh'
  #                      -   The "NO CONCURRENT RSYNC-BACKUP PROCESS" subsection "Option 2b" isn't working as it should.  
  #                              For some reason line 566's " if [[ $(elementIn "$g" "${SCRIPT_PPIDs[@]}") == 0 ]] "
  #                              results in the script terminating with terminal output "killed", when it shouldn't.
  #                              It would therefore appear that function elementIn() is faulty - I recommend debugging in
  #                              Visual Studio Code's debugger.
  #
  #                              ***FOR NOW THOUGH: I have disabled all checking for concurrent processes, with the intention of returning later.
  #                              ***                 I also STRONGLY suggest to remove the concurrency-checking code and instead implement
  #                              ***                 a seperate script to do the checking on its behalf.  This will eleviate the sheer bulk
  #                              ***                 of the code already included in this script; and frankly shouldn't have to be part of
  #                              ***                 its functionality in any ways!
  #
  #				        v1.26	- automatic hostname assigned to SERVER_NAME (i.e. $HOSTNAME)
  #				        v1.25	- update regex value to include reference to rsync (e.g. regex="rsync.*$targetDir"
  #						          - under NO CONCURRENCY section changed to option 1 (i.e. kill this script instance if the previous on is still running)
  #
  #				        v1.24	- checking that /path/to/script/backup-info directory exists
  #				        v1.23	- slight change to the test condition under the PURGE OLD INCREMENTAL BACKUP section
  #				        			> from      if [[ ! "$CURRENT_NUM_INCREMENTALS" < "$MAX_NUM_INCREMENTALS" ]]; then
  #				        			  to		if [[ "$CURRENT_NUM_INCREMENTALS" -gt "$MAX_NUM_INCREMENTALS" ]]; then			
  #
  #				        v1.22	- changes to comments (added 'IMPORTANT', 'DESCRIPTION', etc.)
  #				        v1.21	- a bit of tidying up
  #				        v1.20
  #				        		- purge old incremental backups
  #				        				> user sets the MAX_NUM_INCREMENTALS (maximum number of incremental backups to store),
  #				        				  and the script will automatically purge the oldest (by date-time name) before creating a new incremental.
  #				        v1.11	- rsync: 	
  #				        				> include -A option; preserve ACLs (extended permissions, also implies -p)
  #				        				> add std err redirection log file ERROR_LOG - over and above rsync --log-file - so as to record rsync and general errors in SEPERATE logs. 
  #				           		- misc. changes
  #
  #				        v1.1. 	- Prevents concurrent rsync process - with the same 'signature' as what this script has.
  #				           			ie. If a previous version of this script is still running in memory; that script is terminated
  #				        				before this one is started up.
 #
 #INSTRUCTIONS:	Very little required to tweak for different backup scenarios 
  #				1. FOR DIFFERENT BACKUP TYPES, BACKUP SOURCES, HOSTS etc.:   
  #					a) simply review and edit the ./backup.conf file as instructed.
  #				2. FOR FILEs/DIRs TO BACKUP:
  #					a) simply edit the ./toBackup.txt file as instructed.
  #
 #
 #REQUIREMENTS:	
  #				1. System software:
  #					a) Rsync
  #					b) SSH - with hosts configured for RSA public/private key pair - 'sshKey' variable pointing to private key
  #					c) *OPTIONAL:  A local, send-only SMTP server (e.g. Postfix) - no dedicated email or 3rd party SMTP server is required
  #						Postfix configured to forward all system-generated email sent to root, to skyqode@gmail.com
  #						(see documentation or https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-postfix-as-a-send-only-smtp-server-on-ubuntu-14-04)
  #				2. User software:
  #					a) Program path - if not in system path already - should be listed (see RESOURCE FILES section)  
 #
# -------------------------------------------------------------------------------------------------------------------
##FUNCTIONS
 #
 ## function top_level_parent_pid ()
  #	A simple (recursive) script to get the top-level parent PID of any process number you give it 
  #	(or the current shell if you leave out the PID argument), upto but not including the PID of 
  #	process /sbin/init (1) - the top-most process of all processes
  #
 function top_level_parent_pid () {
	#echo -e "\nDEBUG: inside function top_level_parent_pid ()"
	#read -p   "DEBUG: Press [Enter] key to continue#targetDir=/mnt/dycom_rsync_bkp1/backups_shared			#location (on local host) to backup to..." key

    # Look up the parent PID (PPID) of the given PID.
    local pid=${1:-$$}		#note: ${1} = $1	
							# syntax:  ${parameter:-word}  where symbol combo ':-' (without quotes) is used when you want to use a default value in case no value exists
							#	ie. if 'parameter' is null or unset, it will expand to 'word', otherwise it will expand to 'parameter',
							#	e.g. it will be similar to ${parameter} if 'parameter' is null or unset
							#	( more info at https://www.debuntu.org/how-to-bash-parameter-expansion-and-default-values/ )
    local stat=($(</proc/${pid}/stat))	# /proc/pid/stat = array of tabspaced statistics from last reboot  [ alternatively: stat=($(cat /proc/$pid/stat))	]
    local ppid=${stat[3]}					# 3rd element in array 'stat' = PPID 	[ alternatively:  ppid=$PPID ]

    # /sbin/init always has a PID of 1, so if you reach that (the recursion terminating condition), 
	# the current PID is the top-level parent (or highest ancestor). Otherwise, recursively keep looking.
    if [[ ${ppid} -eq 1 ]] ; then
        echo ${pid}					# echoed to standard out (i.e. effectively 'returned' to caller where it can be saved to a variable)
    else
        top_level_parent_pid ${ppid}
    fi
	
	return
 }

 ## function parent_pids ()
  #   A simple (recursive) script to retrieve (ie. set elements to array reference received) the current process ID (PID), 
  #   and all parent process IDs (all ancestors) of any process number you give it (or the current shell if you leave out 
  #   the PID argument), upto but not including the PID of process /sbin/init (1) - the top-most process of all processes
  #
 function parent_pids () {
  
  ##LOCAL VARIABLES
  # Determined by the number of arguments received
  #
  case $# in
    # if 1 arg. received from caller:    
    1)  if [[ $1 =~ ^[0-9]*$ ]]   #if arg ($1) is an integer, ie. $1 matches with regex pattern of an integer number ONLY
        then
          #$1 is likely a PID number; save this PID number
          local pid=$1            
        else
          #$1 is likely NOT a PID number
          local pid=$BASHPID          #default PID number is assumed to be the current running process's PID number; alt. local pid=$$

          #$1 is likely a ref. to an array - save it, but ONLY if it doesn't already exist (you don't want to overrite it on subsequent recursions of this function)
          if [[ -z "$ppidArrayRef" ]]; then 
            local -n ppidArrayRef=$1    #store reference to array ($1)
            ppidArrayRef[0]=$pid        #0th element must be the current process's ID number (subsequent elements to be parent PIDs recursively)
          fi
          
        fi;;         
    # if 2 args received from caller:    
    2)  if [[ $1 =~ ^[0-9]*$ ]]   #if arg ($1) is an integer 
        then
          #$1 is likely a PID number; $2 is likely a ref. to an array; save both
          local pid=$1
          local -n ppidArrayRef=$2
        else
          #must be a mistake, exit with an error (1)
          echo -e "\n FATAL ERROR: Function expects arg1 to be an integer, and arg2 to be a ref. to an array variable."
          return 1
          #exit 1          
        fi;;
    # if any other number arguments received from caller:
    *)  echo -e "\nFATAL ERROR:  Incorrect number arguments received.  Terminating process."
        return 1
        #exit 1
        break;;
  esac      

  local stat=($(</proc/${pid}/stat))	# /proc/pid/stat = array of tabspaced statistics from last reboot  [ alternatively: stat=($(cat /proc/$pid/stat))	]
  local ppid=${stat[3]}					# 3rd element in array 'stat' = PPID 	[ alternatively:  ppid=$PPID ]      

  # /sbin/init always has a PID of 1, so if you reach that (the recursion terminating condition), 
  # the current PID is the top-level parent (or highest ancestor). Otherwise, recursively keep looking.
  if [[ ${ppid} == 1 ]] ; then
    #declare -a ppidArrayRevOrder		#same as ppidArrayRef, but in reverse order

	#    #Use C-style for-loop to revserse order of all elements of array ppidArrayRef, so as to have PIDs in order of ancestry.
	#    for (( index=${#ppidArrayRef[@]}-1 ; index>=0 ; index-- )) {
	#        ppidArrayRevOrder=("${PPIDarrRevOrder[@]}" "${PPIDarr[$index]}")
    #   }
	return 	#terminate this function and return to caller	
  else
	  ppidArrayRef=("${ppidArrayRef[@]}" "$ppid")	#append ppid to END of array PPIDarr	
	  parent_pids ${ppid}	              #recurse, passing the ppid as the argument
  fi
    
  return    
 }

 ## function elementIn ()
  #   Small function to check if an array contains a value. 
  #   The search string is the first argument ($1) and the second ($2) is the array passed by reference
  #   with which to search in.
  #
  #	NOTE: array passed by reference possible in BASH 4.3+
  #
 function elementIn () {
  #DEBUG LINE: comment in/out as necesarry
  echo -e "DEBUG:  inside function elementIn"

  #local USAGE="Usage: elementIn \"searchString\" \"\${array[@]}\""
  local USAGE="Usage: $0 \"searchString\" arrayName"
  
  ##CHECK PARAMS RECEIVED AND SET DIR & REGEX VARs
  #	Return to caller if either 1st ($1) or 2nd parameter ($2) passed is zero
  # Else, set local variables
  #
  if [[ ("$#" == "0") || (-z "$2") || (-z "$1") ]]; then
	  echo "$USAGE"
	  #exit 1
    return 1  
  fi

  #DEBUG LINE: comment in/out as necesarry
  echo -e "DEBUG:  \n1st param (search string):  $1   \n2nd param (array by ref.): $2"

  local str="$1"				#search string to check for
  #local -n arr=$2				#array to search in;  -n switch required to make array reference (point to) another array
              #("${arr[@]}")
  #declare -a arr=("$2")  
  #declare -a arr         #local copy of array elements in $2: default empty
  declare -n arr=$2       #ref. to array received
  declare -i idx=0        #index (integer)  alt.: local -i idx=0  (local = declare)
  
  #populate empty local array
  #for el in $2
  #do
  #    arr[idx]="$el"
  #    idx+=1        #increment index for next iteration
  #done  

  #DEBUG: comment in as required
  echo -e "\nDEBUG: elements in local/referenced array arr[]:"
  for el in ${arr[*]}; do echo "$el"; done

  #DEPRECATED: shift each positional parameter (arguments passed to this function) by 1
  #shift 		#'shift n' will shift positional parameters to left by n (default n=1), 
  				#	eg. if 3 parameters passed to function, then 'shift 2' will make $3 the new $1, $2 the new $0, and $1 the new $3 
  
  #string comparison
  for el in "${arr[*]}" 
    #do [[ "$e" == "$str" ]] && return 0	#if match found, return success (0)
  do
    if [[ "$el" == "$str" ]]; then 
      #DEBUG: comment in as required
      echo -e "\nDEBUG:	PID $str found in array arr[]"      
      return 0    #if match found, return success (0) exit status
    else
      #DEBUG: comment in as required
      echo -e "\nDEBUG:	PID $str NOT found in array arr[]"      
      return 1    #if no match found, return fail (1) exit status
    fi
  done  
  
  #else - element not found - return fail (1)
  return 1
 }

 ## function readLinesIntoArray () 
  #   @description:   reads each line in a file to an array
  #   @parameters:    $1 = file or directory name (absolute path)
  #                   $2 = array passed by reference
  #
 function readLinesIntoArray () {
  local DEBUG=0             #flag, default 0 (false in '$(( ))' integer testing)
  local EXIT_STATUS=0       #default 0 (success)
  declare -n arr=$2         #reference to array in parameter $2
  local filename="$1"       
  
  #function must receive 2 arguments, of which the first ($1) may not be an empty string
  if [[ $# -ne 2 || -z "$filename" || ! -f "$filename" ]]; then 
    echo ""
    echo "Bad Usage of function readLinesArray(), or file name not supplied."
    echo "Usage:  readLinesArray <filename> <arrayname>"
    echo ""

    EXIT_STATUS=1
    return $EXIT_STATUS
  fi  

  ##DEBUG: output every line as its read
   local c=0               #counter
   if (( $DEBUG )); then 
    echo "DEBUG: file path is $2"
    while read line; do
      # reading each line
      echo "Line No. $c: $line"
      c=$((c+1))
    done < $filename
   fi
  #

  ##Read every line in file 'filename' into the referenced array 'arr'
  local index=0           #index counter
  while read line; do
    #skip lines containing comment-out signs '#' or ';'
    if [[ ( $line == *"#"*  || $line == *";"* ) ]]; then 
      continue
    else 
      arr[$index]="$line"     #assign the array element
      index=$((index+1))      #increment the array index
    fi    
    #increment counter
    c=$((c+1))    
  done < $filename

  return $EXIT_STATUS
 }

 ## function printUsage ()
  #	Prints to standard out the correct usage of this script.
  #	@param: 	--debug
  #	@returns:	exit status 0
  #
 function printUsage () {  
    echo ""
    echo "DESCRIPTION: "
    echo "  $0 is a FULL (image) backup script which syncs data - files and directories listed "
    echo "  in ./toBackup.txt - either between a remote and local host, local to local host, or "
    echo "  local to remote host."
    echo "  ONLY in the first scenario is data PULLed from the remote host (as opposed to the "
    echo "  remote host instigating the transfer by PUSHing the data).  The other two scenarios PUSHes data."
    echo ""
    echo "  Configuring the backup script is done via ./backup.conf."
    echo ""
    echo "REQUIREMENTS:"
    echo "  1. Configuration files:     ./toBackup.txt, ./backup.conf"
    echo "  2. Temp storage direcotry:  ./backup-info"
    echo "  3. SSH"
    echo "  4. Supporting scripts under path ./files are: "
    echo "      fileExist.sh, getAddr.sh, getRsyncPID.sh, lsDirSSH.sh, duDirSSH.sh, killProc.sh, "
    echo "      getValFromFile.sh, purgeOldestFileOrDirSSH.sh, fileOrDirExists.sh"    
    echo ""
    echo "SYNTAX: "
    echo "  $0 [--debug] [--help]"
    echo ""
    echo "  where:"
    echo "      --debug     : OPTIONAL:  interactive outputs & debugging."
    echo "      --help      : OPTIONAL:  prints to stdout this text."
    echo ""
  return 0
 }

 ## function printScriptRunStatus ()
  # Function that prints the running status of the script, by checking if file in $1 exists. 
  # parm: ($1) filename  - indicate whether this file exist or not with a nice looking echo to stdout
  #
 function printScriptRunStatus () {    
    if [[ -f "$1" ]]; then 
        echo -e "\nScript running status: running."
    else 
        echo -e "\nScript running status: stopped."
    fi    

    return 0
 }

 ## function scriptIsRunning ()
  # Function echoes to stdout either '1' (caller to interpret script is running) or '0' (not running)
  # parm:   ($1) filename  - indicate whether this file exist or not with a nice looking echo to stdout
  #
 function scriptIsRunning () {
  if [[ -f "$1" ]]; then 
    echo "1"    #caller to interpretate as true
  else 
    echo "0"    #caller to interpreate as false        
  fi

  return
 }

 ## function setScriptRunFlag ()
  # parm: ($1) filename  - create this file if it doesn't exist
 function setScriptRunFlag () {
  echo -e "\n...script should RUN now"
  if [[ -f "$1" ]]; then return 0; else touch "$1"; fi
  return $?
 }

 ## function stopScriptRunFlag ()
  # parm: ($1) filename  - remove this file if it exists
 function stopScriptRunFlag () {
  echo -e "\n...script should STOP now"
  if [[ -f "$1" ]]; then rm -f "$1"; else return 0; fi
  return $?
 }

 ## function pressAnyKey ()
  # Interactive pause of process until any key pressed (key not stored)
  #
 function pressAnyKey () {
  echo ""
  read -p "Press [Enter] key to continue..." key
  echo ""

  return 0
 }

# ------------------------------------------------------------------------------------------------------------
##GENERAL VARIABLES
# -----------------
 EXIT_STATUS=0       #default 0 (success)
 DEBUG=0             #flag to flip debug interactive output (default: 0, off)

 datetime=$(date '+%Y-%m-%d@%H:%M:%S')                   #date & time now (e.g. 2018-09-09@16:54:10)
 CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"	#path of this script
 resourceDir="$CURRENT_DIR/files"                        #helper scripts
 backupConfig="$CURRENT_DIR/backup.conf"		#configuration file: file used to populate ALL script variables
 filesAndDirsToBackup="$CURRENT_DIR/toBackup.txt"         #file that containts the directories or files (absolute paths) to backup
 ExcludeList=$CURRENT_DIR/backup_exclude_list.txt		#files to exclude in this backup (if any); if absent, rsync will ignore and continue.
 SERVER_NAME="$HOSTNAME"									#name of server running this script
 SERVER_IP="$(ip -4 addr show scope global | grep -Evi "(secondary|inet6|"127.0.0.1"|"10.1.1"|"10.8.0")" | awk '$1 == "inet" {print $2}' | sed 's/\/.*//')"
 SCRIPT_NAME="$(basename $0)"							#filename of this script (e.g. "backup_home-andre_from_host-dycom_to_3TB.sh")
														              #alternatively: "$(basename ${BASH_SOURCE[0]})"
 #output formatting
 bold=$(tput bold)          #format font in output text to bold
 normal=$(tput sgr0)        #return to previous font

 #a file to identify if a script is running or not (if file exists, then script assumed active, if not then script assumed NOT active)
 scriptRunFlag="$CURRENT_DIR/running..."

 #By default the sync between souce and target dictates that the source directory HAS to exist
 #and absolutely MUST not be empty.  Change this value to 'yes' if the source is allowed to be empty.
 sourceDirMayBeEmpty="$($resourceDir/getValFromFile.sh "$backupConfig" "sourceDirMayBeEmpty")" 
 if [[ -z "$sourceDirMayBeEmpty" ]]; then sourceDirMayBeEmpty="no"; fi

 #As for the source directory, same default applies
 targetDirMayBeEmpty="$($resourceDir/getValFromFile.sh "$backupConfig" "targetDirMayBeEmpty")"
 if [[ -z "$targetDirMayBeEmpty" ]]; then targetDirMayBeEmpty="no"; fi

 #error & rsync log files 
 RSYNC_LOG="rsync-$datetime.log"							#to record all rsync output
 ERROR_LOG="error-$datetime.log"							#to record all error messges (rsync or otherwise) - this will be the file to be revied by admin

 ##default email error notification message, subject and receiver
 EMAIL_RECEIVER="root"
 EMAIL_SUBJECT="Script Error(s) From: $SERVER_NAME"
 EMAIL_MESSAGE="Script Error(s) From: $SERVER_NAME\nScript path: $CURRENT_DIR/$SCRIPT_NAME\nPlease review log-file: $backupInfoDir/$ERROR_LOG or $targetDir/$datetime/$ERROR_LOG on destination host" 
  
 #INCLUSION TO REVIEW
 #--------------------
 SCRIPT_PID="$BASHPID"						#this scripts process ID number
 SCRIPT_PPID="$PPID"						  #this scripts direct parent process ID number
 #SCRIPT_PPIDs="$(parent_pids)"			#array containing this script's process ID, and all of its ancestor's PIDs (upto but excluding PID 1)
 declare -a SCRIPT_PPIDs					#(default unset) array containing this script's process ID, and all of its ancestor's PIDs (upto but excluding PID 1)		
 #parent_pids SCRIPT_PPIDs				#passing name of array to function where it can be set
 parent_pids $SCRIPT_PID SCRIPT_PPIDs				#passing name of array to function where it can be set
 SCRIPT_TOPLEVEL_PPID="$(top_level_parent_pid)"			#this script's top-level parent process ID number (ie. highest ancestor PID number, just before 1 (/sbin/init))
 #--------------------
#

##TRAPS (catch/trap signal handlers)
# --------------------------------- 
 #Trap (catch) either signals EXIT (ie. exit command), 1 (HUP/SIGHUP), 2 (INT/SIGINT), 3 (SIGQUIT), 15 (SIGTERM), or 20/terminal-stop (SIGTSTP/TSTP)
  #and then:
  #   1. remove the 'running...' file (indicating the script has stopped running)
  #   2. call exit (EXIT) signal to terminate the script if the intention is for the script NOT to continue with the rest 
  #      of the program after the trap, but return to the parent process.
  #  
  #syntax:
   #   set the trap:        trap [commands] [signals]
   #   remove the trap:     trap <-> [signals]   OR  trap [signals]
   #
   #      where:  <commands> is any (semi-colon seperated) number of commands or function-calls, and
   #              <signal> is either the signal name or signal number to be caught.
   #
   #   e.g.1
   #      trap "echo Booh!" 2 3 9
   #
   #   e.g.2
   #      function myFunc () { rm -r /path/to/dir/to/delete }
   #      function myFunc2 () { echo "All done!"; return 0 }
   #	     trap "{ myFunc; myFunc2; }" EXIT
  # 
  #signals (kill -l to see complete list):   
   #    Signal Name 	Signal Number 	Description
   #    -----------------------------------------
   #    SIGHUP 	      1 	            Hang up detected on controlling terminal or death of controlling process
   #    SIGINT        2 	            Issued if the user sends an interrupt signal (Ctrl + C)
   #    SIGQUIT 	    3 	            Issued if the user sends a quit signal (Ctrl + D)
   #    SIGFPE 	      8 	            Issued if an illegal mathematical operation is attempted
   #    SIGKILL 	    9 	            If a process gets this signal it must quit immediately and will not perform any clean-up operations
   #    SIGALRM 	    14 	            Alarm clock signal (used for timers)
   #    SIGTERM 	    15 	            Software termination signal (sent by kill by default)
  #   
#
trap "{ stopScriptRunFlag $scriptRunFlag; 
        (($DEBUG)) && printScriptRunStatus $scriptRunFlag; 
        exit 1; 
      }" HUP INT QUIT TERM TSTP


##CODE
# ----
#

 ##INITIALIZE ERROR & RSYNC LOG FILEs
  # ----------------------------------
 echo "" > "$backupInfoDir/$RSYNC_LOG"					#to save *all* rsync output; make the log file that has timestamp in filename
 echo "" > "$backupInfoDir/$ERROR_LOG"					#to save *only* rsync errors (ie. std err output)

##prevent concurrency - ie. if previous instance of this (exact) script is still active, then log it and terminate the script.
#
if (( $(scriptIsRunning $scriptRunFlag) )); then   
  #construct error message
  errMsg="\nERROR:  Concurrent instances of this script not allowed!!"	
	errMsg+="\n\n   A previous instance of this script appears to be running as indicated by the"
  errMsg+="\n   presence of the 'running...' (or similar) text file in the file path of the script."
  errMsg+="\n\n   If this is not the case, then the text file may be removed manually, followed by"
  errMsg+="\n   executing the script again."
  errMsg+="\n\n   Terminating this new instance...\n"
  
  #echo error message to stdout
  echo -e "$errMsg"
  
  #send email notification
	echo -e "$errMsg" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER  

  ##DEBUG:
   if (( $DEBUG )); then
    echo ""
    read -p   "DEBUG: Press [Enter] key to continue..." key
    echo ""
   fi
  #  

  #terminate this script
  exit 1
fi

##No concurrent instances....
# ...so set the running flag status (create ./running... file) to indicate the start of the script
#
(( $DEBUG )) && echo -e "\nSetting flag to indicate script is RUNNING"
setScriptRunFlag "$scriptRunFlag"
if [[ $? -ne 0 ]]; then
  #construct error message
  errMsg="\nERROR:  Running indicator appears not to be working..."
  errMsg+="\n   Please ensure write permission to script file path, or run script with sudo privaleges."
  errMsg+="\n"
  errMsg+="\n   Terminating script..."
  errMsg+="\n"

  #echo error message to stdout AND error log file
  echo -e "errMsg" 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"

  #send email notification
	echo -e "$errMsg" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER 

  #terminate this script
  stopScriptRunFlag "$scriptRunFlag"
  (($DEBUG)) && printScriptRunStatus $scriptRunFlag && pressAnyKey
  exit 1
fi
(( $DEBUG )) && printScriptRunStatus "$scriptRunFlag"


##Process optional script agruments received:
# individually loop through every argument received ($1,$2,... $n), assigning to appropriate VARs    
for i in "$@"; do                                                                   
    if [[ "$#" == "0" ]]; then break
    elif [[ $i == "--debug" ]]; then DEBUG=1    
    elif [[ $i == "--help" ]]; then 
      printUsage
      
      #terminate script
      stopScriptRunFlag "$scriptRunFlag"
      (($DEBUG)) && printScriptRunStatus $scriptRunFlag && pressAnyKey
      exit $EXIT_STATUS

    else 
        printUsage        

        #terminate script
        stopScriptRunFlag "$scriptRunFlag"
        (($DEBUG)) && printScriptRunStatus $scriptRunFlag && pressAnyKey
        exit $EXIT_STATUS
    fi
done

##DEBUG: comment in when troubleshooting
 if (( $DEBUG )); then
  echo -e "\nDEBUG: SCRIPT_NAME = $(basename $0)"
  echo -e "\nDEBUG: Current PID: $BASHPID		PPID: $PPID		Top-level PPID: $(top_level_parent_pid)"
  echo ""
  read -p   "DEBUG: Press [Enter] key to continue..." key
  echo ""
 fi
#

##CONFIRM BACKUP LOG FILE DIRECTORY EXISTS
# If not, create it, incl. the time_now.txt tracking file
# ------------------------------------------------------------
backupInfoDir="$CURRENT_DIR/backup-info"				#log files
if [[ ! -d $backupInfoDir ]];
then
  mkdir -p $backupInfoDir
  MAKE_DIR_EXIT_STATUS=$?
  
  chown -R root:root $backupInfoDir
  CHOWN_EXIT_STATUS=$?
  
  chmod 777 -R $backupInfoDir
  CHMOD_EXIT_STATUS=$?
  
  if [[ $MAKE_DIR_EXIT_STATUS -ne 0 ]] || [[ $CHOWN_EXIT_STATUS -ne 0 ]] || [[ $CHMOD_EXIT_STATUS -ne 0 ]]
  then
  	errMsg="\nERROR:  Backup info directory ($backupInfoDir) does not exist, or has failed to be created with the required permissions."	
	  errMsg+="\nPlease ensure you have write/execute permissions, or execute the command with sudo/admin privaleges."
	  echo -e "$errMsg" >> "$backupInfoDir/$ERROR_LOG"
	  echo -e "$EMAIL_MESSAGE" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER

    #terminate script
    stopScriptRunFlag "$scriptRunFlag"
    (($DEBUG)) && printScriptRunStatus $scriptRunFlag && pressAnyKey
	  exit 1
  else
    #write new timestamp string into new time.txt file - i.e. time.txt now contains current date-time string
    echo $datetime > $backupInfoDir/time_now.txt
  fi
fi

# confirm the time_now.txt tracker file exists - if not create it, containing the current datetime stamp
if [[ ! -r $backupInfoDir/time_now.txt ]]; then
    #write new timestamp string into new time.txt file - i.e. time.txt now contains current date-time string
    echo $datetime > $backupInfoDir/time_now.txt
fi


##CHECK RESOURCE VARIABLES - typically supporting scripts
# -------------------------------------------------------
#
#Array containing the required supporting script file names
#  (NOTE: 0th entry **must** be file fileExist.sh)
resourceFiles=("fileExist.sh" "getAddr.sh" "getRsyncPID.sh" "lsDirSSH.sh" "duDirSSH.sh" "killProc.sh" "getValFromFile.sh" "purgeOldestFileOrDirSSH.sh" "fileOrDirExists.sh")
FILE_EXIST=false										#flag: default = false

#check resource directory and resource file(s) exists - log if not, then terminate (else continue script)
if [[ -d $resourceDir ]]; then
  
  #first check if critical program fileExist.sh exists under the resource directory - log if not, then quite this script.
  if [[ ! -r $resourceDir/${resourceFiles[0]} ]]; then
  	echo -e "\nCRITICAL ERROR:  program ${resourceFiles[0]} missing from path $resourceDir." >> "$backupInfoDir/$ERROR_LOG"		#prev.: echo -e "\nCRITICAL ERROR:  program ${resourceFiles[0]} missing under directory $resourceDir." >> "$backupInfoDir/rsync-$datetime.log"
	  echo -e "$EMAIL_MESSAGE" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER

    #terminate script
    stopScriptRunFlag "$scriptRunFlag"
    (($DEBUG)) && printScriptRunStatus $scriptRunFlag && pressAnyKey
  	exit 1
  fi
  
  #check required resourceFiles exist in resourceDir, and read permission is granted (-r)
  for rf in ${resourceFiles[*]}
  do  	 
    FILE_EXIST="$($resourceDir/${resourceFiles[0]} $rf $resourceDir)"
	if [[ $FILE_EXIST != 'true' ]]; then 
		echo -e "\nCRITICAL ERROR:  program $rf missing from $resourceDir." >> "$backupInfoDir/$ERROR_LOG"		#prev.: echo -e "\nCRITICAL ERROR:  program $rf missing under directory $resourceDir." >> "$backupInfoDir/rsync-$datetime.log"
		echo -e "$EMAIL_MESSAGE" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER

    #terminate script
    stopScriptRunFlag "$scriptRunFlag"
    (($DEBUG)) && printScriptRunStatus $scriptRunFlag && pressAnyKey    
		exit 1
	fi		
  done
  
else
	echo -e "\nCRITICAL ERROR:  missing resource directory $resourceDir." >> "$backupInfoDir/$ERROR_LOG"			#prev.: echo -e "\nCRITICAL ERROR:  missing resource directory $resourceDir." >> "$backupInfoDir/rsync-$datetime.log"
	echo -e "$EMAIL_MESSAGE" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER

  #terminate script
  stopScriptRunFlag "$scriptRunFlag"
  (($DEBUG)) && printScriptRunStatus $scriptRunFlag && pressAnyKey  
	exit 1
fi


##SOURCE HOST VARIABLES - i.e. backup source
# ------------------------------------------
# populate variables from config file (backup.conf)
# 
#absolute paths to content (files/dirs) to backup from source host - indexed array (default empty); alt. syntax: array=()
declare -a arrOfSrcFilesAndDirs                         

#retrieve source host address (either local or remote)
sourceAddress="$($resourceDir/getValFromFile.sh "$backupConfig" "sourceAddress")"
if (( $DEBUG )); then echo "DEBUG: sourceAddress set 1st time to $sourceAddress"; fi

#sources's IP address and host/domain name respectively (to be tested for reachability)
s_addr1="$($resourceDir/getValFromFile.sh "$backupConfig" "s_addr1")"          
s_addr2="$($resourceDir/getValFromFile.sh "$backupConfig" "s_addr2")"

#user credentials with which to authenticate on source (login name, ssh key, tcp port ssh listens at)
s_userName="$($resourceDir/getValFromFile.sh "$backupConfig" "s_userName")"
s_sshKey="$($resourceDir/getValFromFile.sh "$backupConfig" "s_sshKey")"
s_sshPort="$($resourceDir/getValFromFile.sh "$backupConfig" "s_sshPort")"
#xxx="$($resourceDir/getValFromFile.sh "$backupConfig" "xxx")"

#source host cannot be both local host and remote host
if [[ $sourceAddress == "localhost" && ( ! -z "$s_addr1" || ! -z "$s_addr2" ) && ! -z "$s_userName" && ! -z "$s_sshKey" ]]; then 
    echo ""
    echo "WARNING:  Config file appears to be pointing to both local and remote source host!" >> "$backupInfoDir/$ERROR_LOG"
    echo "Assuming local host." >> "$backupInfoDir/$ERROR_LOG"
    echo ""
    sourceAddress="localhost"
fi

#Call external getAddr.sh script to retrieve first of two remote host addresses that is reachable.  Else empty string.
if [[ "$sourceAddress" != "localhost" ]]; then
    sourceAddress="$($resourceDir/getAddr.sh "$s_addr1" "$s_addr2")"
    if (( $DEBUG )); then echo "DEBUG: sourceAddress set 2nd time to $sourceAddress"; fi
fi


##TARGET HOST VARIABLES - i.e. backup target
# -----------------------------------------
# populate variables from config file (backup.conf)
#
#location (on local or remote host) to backup to
targetDir="$($resourceDir/getValFromFile.sh "$backupConfig" "targetDir")"
targetAddress="$($resourceDir/getValFromFile.sh "$backupConfig" "targetAddress")"

#target's IP address and host/domain name respectively (to be tested for reachability)
t_addr1="$($resourceDir/getValFromFile.sh "$backupConfig" "t_addr1")"
t_addr2="$($resourceDir/getValFromFile.sh "$backupConfig" "t_addr2")"

#user credentials with which to authenticate on target (login name, ssh key, tcp port ssh listens at)
t_userName="$($resourceDir/getValFromFile.sh "$backupConfig" "t_userName")"
t_sshKey="$($resourceDir/getValFromFile.sh "$backupConfig" "t_sshKey")"
t_sshPort="$($resourceDir/getValFromFile.sh "$backupConfig" "t_sshPort")"
#xxx="$($resourceDir/getValFromFile.sh "$backupConfig" "xxx")"

#target host cannot be both local host and remote host
if [[ "$targetAddress" == "localhost" && ( ! -z "$t_addr1" || ! -z "$t_addr2" ) && ! -z "$t_userName" && ! -z "$t_sshKey" ]]; then 
    echo ""
    echo "WARNING:  Config file appears to be pointing to both local and remote source host!" >> "$backupInfoDir/$ERROR_LOG"
    echo "    Assuming local host." >> "$backupInfoDir/$ERROR_LOG"
    echo ""
    targetAddress="localhost"
fi

#if target is NOT local, call external getAddr.sh script to retrieve first 
#of two remote host addresses that is reachable.  Terminate script if remote target not found.
if [[ "$targetAddress" != "localhost" ]]; then 
    targetAddress="$($resourceDir/getAddr.sh "$t_addr1" "$t_addr2")"
    if (( $DEBUG )); then echo "DEBUG: targetAddress set 1st time to $targetAddress"; fi
    
    #if target address does not exist (ie. empty); do some housekeeping then terminate the script.
    if [[ -z "$targetAddress" || $targetAddress == "" ]]; then
      echo ""
      echo -e "CRITICAL ERROR:  Target host ($t_addr1 or $t_addr2) could NOT be found.  \n\nTerminating script..." 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"
      echo ""
      echo -e "$EMAIL_MESSAGE" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER    

      stopScriptRunFlag "$scriptRunFlag"
      (($DEBUG)) && printScriptRunStatus $scriptRunFlag && pressAnyKey

      exit 1
    fi
fi


##PURGE OLDEST INCREMENTAL BACKUP BEFORE CONTINUING (if the max number of incrementals is exceeded)
# -------------------------------------------------------------------------------------------------
#retrieve max no. incremental backups to store.  Default: 42, e.g. 6/day @ 7 days = 42 max no. of incremental backups.
MAX_NUM_INCREMENTALS="$($resourceDir/getValFromFile.sh "$backupConfig" "MAX_NUM_INCREMENTALS")"
if [[ -z "$MAX_NUM_INCREMENTALS" || $MAX_NUM_INCREMENTALS == "" ]]; then MAX_NUM_INCREMENTALS=42; fi  

if [[ "$targetAddress" == "localhost" ]]; then 
  INCREMENTAL_BACKUPS="$(ls -lA "$targetDir/" | grep -E '^d')"			#list of all the incremental backup directories - sorted by name 
																		                              #	ls -A   = list excl. directories . & ..
																		                              #	|				= pipe output to
																		                              #	grep -E '^d'	= match every line piped by first character that equals 'd'
else
  INCREMENTAL_BACKUPS="$($resourceDir/lsDirSSH.sh "$targetDir" "$t_userName@$targetAddress" "$t_sshKey" "$t_sshPort" | grep -E '^d')"           #lsDirSSH.sh syntax: <REMOTE_FILE_OR_DIR> <REMOTE_HOST> <SSH_KEY> <TCP_PORT>
fi
																		
CURRENT_NUM_INCREMENTALS=$(echo "$INCREMENTAL_BACKUPS" | wc -l)			#number of incremental backup folders (i.e. number of incremental backups effectively)
																		#	wc -l			= count the number of lines

# purge oldest incremental backup **directory** in the target directory (local or remote) if MAX_NUM_INCREMENTALS equaled or exceeded
#
if [[ $CURRENT_NUM_INCREMENTALS -ge $MAX_NUM_INCREMENTALS ]]; then
    if [[ "$targetAddress" == "localhost" ]]; then        
        # syntax:  ./purgeOldestFileOrDirSSH.sh [--debug] <-d|-f> --dir=<"/dir/to/evaluate"> --regex=<"regular-expression"> [ user@host --ssh-key=<key> --port=<port> ]        
        $resourceDir/purgeOldestFileOrDirSSH.sh -d --dir="$targetDir" --regex=".*"
        if [[ "$?" != "0" ]]; then
          echo -e "\WARNING: MAX RSYNC LOG FILES EXCEEDED:  Oldest log file failed to delete.\nManual delete required." >> "$backupInfoDir/$ERROR_LOG"
	        echo -e "$EMAIL_MESSAGE" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER
 	        #exit 1	
        fi
    else
        # syntax:  ./purgeOldestFileOrDirSSH.sh [--debug] <-d|-f> --dir=<"/dir/to/evaluate"> --regex=<"regular-expression"> [ user@host --ssh-key=<key> --port=<port> ]
        $resourceDir/purgeOldestFileOrDirSSH.sh -d --dir="$targetDir" --regex=".*" "$t_userName@$targetAddress" --ssh-key="$t_sshKey" --port="$t_sshPort"
        if [[ "$?" != "0" ]]; then
          echo -e "\nWARNING: MAX RSYNC LOG FILES EXCEEDED:  Oldest log file failed to delete.\nManual delete required." >> "$backupInfoDir/$ERROR_LOG"
	        echo -e "$EMAIL_MESSAGE" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER
 	        #exit 1	
        fi
    fi
fi


##GET THE LIST OF FILE/DIRECTORIES TO BACKUP FROM THE ./toBackup.txt FILE AND STORE IN ARRAY
# ------------------------------------------------------------------------------------------
readLinesIntoArray "$filesAndDirsToBackup" arrOfSrcFilesAndDirs
EXIT_STATUS="$?"

#
if [[ $EXIT_STATUS != 0 ]]; then 
    echo ""
    echo "Bad usage or file name does not exist."
    echo "Usage:  $0 <filename>"
    echo ""

    #terminate script
    stopScriptRunFlag "$scriptRunFlag"
    (($DEBUG)) && printScriptRunStatus $scriptRunFlag && pressAnyKey
    exit $EXIT_STATUS
fi

##DEGUB: output every array element
 if (( $DEBUG )); then
  c=0       #counter
  echo -e "\nDEBUG: content of \${arrOfSrcFilesAndDirs[@]}:\n"
  for ele in ${arrOfSrcFilesAndDirs[@]}; do
    echo "Line No. $c: $ele"
    c=$((c+1))
  done
   
  #reset counter
  c=0
  echo ""  
 fi
#


##SET INCREMENTAL-BACKUP TRACKING FILES
# -------------------------------------
#get last (newest) backup/incremental-backup directory from the TARGET location (local or remote), *if* one exists.
if [[ $CURRENT_NUM_INCREMENTALS > 0 ]]; then
  LAST_BACKUP_DIR="$(echo "$INCREMENTAL_BACKUPS" | sort -rk9,9 | sed -n '1p' | awk '{print $NF}')"  # reverse sort INCREMENTAL_BACKUPS by last column (dir name),
                                                                                                    # piped output then limited to 1st line (newest entry) only,
                                                                                                    # piped output then reduced to last column (time stamp) only.
else 
  LAST_BACKUP_DIR=""
fi

##DEBUG:
 if (( $DEBUG )); then 
    echo ""
    echo "DEBUG: LAST_BACKUP_DIR = $LAST_BACKUP_DIR"
    echo ""
    read -p "DEBUG: Press [Enter] key to continue..." key  
    echo ""
 fi
#

#if no previous backup directory exists (ie. this will be the first one)... 
if [[ -z "$LAST_BACKUP_DIR" ]]; then
  #...this is the very first backup - let the backup directory be named the timestamp of the time now
  #ie. copy contents (date-time named string) from time_now.txt to time_before.txt (time_before.txt = time-date of previous incremental backup)
  yes | cp $backupInfoDir/time_now.txt $backupInfoDir/time_before.txt           # yes pipe is to confirm a 'yes' when prompted
else
  #...write the name of the last backup directory (a date-time string) to time_before.txt (time_before.txt = time-date of previous incremental backup)
  yes | echo "$LAST_BACKUP_DIR" > $backupInfoDir/time_before.txt           # yes pipe is to confirm a 'yes' when prompted
fi

#overwrite old time.txt file with new timestamp string - i.e. time.txt now contains current date-time string
echo $datetime > $backupInfoDir/time_now.txt

##DEBUG:
 if (( $DEBUG )); then 
    echo ""
    echo "DEBUG: time_before.txt = $(cat time_before.txt)"
    echo "DEBUG: time_now.txt = $(cat time_now.txt)"
    echo ""
    read -p "DEBUG: Press [Enter] key to continue..." key  
    echo ""
 fi
#


##RSYNC BACKUP:
# -------------
##get/set switches to apply:
 #       -avzhPR         -a = archive mode, equals -rlptgoD              -v = verbose    -z = compress file data during transfer
 #                       -h = human readible numbers                     -R = use relative pathnames (also creates dirs on the fly)
 #                       -P = combines --progress and --partial (preserves partially transfered files for future completion)
 #						-A = preserves ACLs (Access Control Lists; i.e. extended permissions)
 #       --chmod                 affect file and/or directory permissions
 #       --delete                delete extraneous files from destination directories 
 #       --stats                 stats that are useful to review amount of traffic sent over network (handy for sysadmins)
 #       --log-file              to log rsync output for later review
 #       --exclude-from          contains directory paths (one per line) of what not to backup
 #       --link-dest=DIR         To create hardlink (instead of copy) to files in DIR (previous backup), when files are unchanged.
 #                               This means that the --link-dest command is given the directory of the previous backup (on the target).
 #                               If we are running backups every two hours, and it’s 4:00PM at the time we ran this script, then the 
 #                               --link-dest command looks for the directory created at 2:00PM (on the target/destination path) and
 #                               only transfers the data that has changed since then (if any).
 #
 #                               To reiterate, that is why time_now.txt is copied to time_before.txt at the beginning of the script,
 #                               so the --link-dest command can reference that time (and the folder with the same name) later.
 #
 #       -e                      specify the remote shell to use (e.g. SSH) during the sync.
 #
#
#populate rsync switches; defaults if not set in config file
prelimSwitches="$($resourceDir/getValFromFile.sh "$backupConfig" "prelimSwitches")"
if [[ -z $prelimSwitches || "$prelimSwitches" == "" ]]; then prelimSwitches="-avzhHAPR"; fi

delSwitch="$($resourceDir/getValFromFile.sh "$backupConfig" "delSwitch")"
if [[ -z $delSwitch || "$delSwitch" == "" ]]; then delSwitch="--delete"; fi

statsSwitch="$($resourceDir/getValFromFile.sh "$backupConfig" "statsSwitch")"
if [[ -z $statsSwitch || "$statsSwitch" == "" ]]; then statsSwitch="--stats"; fi

##DEBUG:
 if (( $DEBUG )); then 
    echo "DEBUG: sourceAddress = $sourceAddress"
    echo "DEBUG: s_addr1 = $s_addr1"
    echo "DEBUG: s_addr2 = $s_addr2"
    echo "DEBUG: s_userName = $s_userName"
    echo "DEBUG: s_sshKey = $s_sshKey"
    echo "DEBUG: s_sshPort = $s_sshPort"
    echo "DEBUG: sourceDirMayBeEmpty = $sourceDirMayBeEmpty"
    echo ""
    
    echo "DEBUG: targetAddress = $targetAddress"
    echo "DEBUG: t_addr1 = $t_addr1"
    echo "DEBUG: t_addr2 = $t_addr2"
    echo "DEBUG: t_userName = $t_userName"
    echo "DEBUG: t_sshKey = $t_sshKey"
    echo "DEBUG: t_sshPort = $t_sshPort"    
    echo "DEBUG: targetDirMayBeEmpty = $targetDirMayBeEmpty"
    echo ""

    echo "DEBUG: prelimSwitches = $prelimSwitches"
    echo "DEBUG: delSwitch = $delSwitch"
    echo "DEBUG: statsSwitch = $statsSwitch"
    echo ""
    read -p "DEBUG: Press [Enter] key to continue..." key  
    echo ""
 fi
#

##ITERATE OVER ARRAY OF SOURCE FILES/FOLDERS TO BACKUP AND EXECUTE RSYNC BACKUP:
# Note:
# - Optional rsync switch if you want to change file/directory permission on the fly:  --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r
# - Also, incl. -R switch (relative paths) to maintain directory structure where ever synced to.  eg.: -avzhAPR
#
RSYNC1_EXIT_STATUS=1		#default exit status is 1 (fail)
counter=0  
for fileOrDir in ${arrOfSrcFilesAndDirs[@]}; do         #IF ERROR OCCUR: try double quoting wrap, ie. "${arrOfarrOfSrcFilesAndDirs[@]}"
    ##DEBUG:
     if (( $DEBUG )); then 
      echo "DEBUG: fileOrDir = $fileOrDir"
      echo ""
      read -p "DEBUG: Press [Enter] key to continue..." key  
      echo ""
     fi
    #
    
    ##Check that the target host is reachable, and that the target directory (either on remote or local host) exists.
    # Terminate under the following conditions:
    #	1. directory does not exist.
    #	2. directory exists, but is empty when the targetDirMayBeEmpty flag is set to 'no' (cannot be empty, cannot be 0 bytes in size)
    #
    TEMP_EXIT_STATUS=0   
    if [[ $targetAddress == "localhost" ]]; then
      #syntax: ./fileOrDirExists.sh <file-dir> <\"localhost\"> [yes|no]
      $resourceDir/fileOrDirExists.sh "$targetDir" "$targetAddress" "$targetDirMayBeEmpty"    
      TEMP_EXIT_STATUS="$?"
    else
      #syntax: ./fileOrDirExists.sh  <file-dir> <host-address> <username> <ssh-key> <ssh-port> [yes|no]
      $resourceDir/fileOrDirExists.sh "$targetDir" "$targetAddress" "$t_userName" "$t_sshKey" "$t_sshPort" "$targetDirMayBeEmpty"     
      TEMP_EXIT_STATUS="$?"
    fi    
    if [[ "$TEMP_EXIT_STATUS" != "0" ]]; then                
     
        echo -e "\nERROR:  Backup to target directory ($targetDir) on host ($targetAddress) terminated." 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"
        echo    "One or more of the following occured:" 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"        
        echo    "  1. Either the target directory on the target host, or the target host itself, cannot be found, " 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"        
        echo    "  2. The target directory is empty when not expected to be (see ./backup.conf), " 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"
        echo -e "  3. The user lacks permision to succesfully perform a read or write process.\n" 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"

        echo -e "$EMAIL_MESSAGE" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER

        #terminate script
        stopScriptRunFlag "$scriptRunFlag"
        (($DEBUG)) && printScriptRunStatus $scriptRunFlag && pressAnyKey        
        exit 1        
    fi

    ##Check that the source directory (either on remote or local host) exists.
    # Terminate under the following conditions:
    #	1. directory does not exist.
    #	2. directory exists, but is empty when the sourceDirMayBeEmpty flag is set to 'no' (cannot be empty, cannot be 0 bytes in size)
    # 
    if [[ $sourceAddress == "localhost" ]]; then
      $resourceDir/fileOrDirExists.sh "$fileOrDir" "$sourceAddress" "$sourceDirMayBeEmpty"
      TEMP_EXIT_STATUS="$?"
    else
      $resourceDir/fileOrDirExists.sh "$fileOrDir" "$sourceAddress" "$s_userName" "$s_sshKey" "$s_sshPort" "$sourceDirMayBeEmpty"
      TEMP_EXIT_STATUS="$?"
    fi
    if [[ "$TEMP_EXIT_STATUS" != "0" ]]; then     
    
        echo -e "\nERROR:  Backup of the source file/directory ($fileOrDir) skipped." 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"
        echo "One or more of the following occured:" 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"
        echo "  1. Either the source host ($sourceAddress) or source file/directory ($fileOrDir) cannot be found on the the source host, " 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"
        echo "  2. The source directory is empty when not expected to be, " 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"
        echo -e "  3. The user lacks permision to succesfully perform a read or write process.\n" 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"
        
        echo -e "$EMAIL_MESSAGE" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER        
        continue    #skip this iteration of parent for-loop
    fi

    ##DEBUG:
     if (( $DEBUG )); then 
        echo "DEBUG: fileOrDir = $fileOrDir"
        echo "DEBUG: sourceAddress = $sourceAddress"
        echo "DEBUG: targetAddress = $targetAddress"
        echo ""
        read -p "DEBUG: Press [Enter] key to continue..." key  
        echo ""
     fi
    #

    #refresh script run status
    setScriptRunFlag "$scriptRunFlag"

    ##Now that you've confirmed both source and target hosts, commence the rsync backup for ONE of the following scenarios (only):
    # 1. from remote source to local target (ie. data PULLed from remote source, to local target):
    if [[ "$sourceAddress" != "localhost" ]] && [[ "$targetAddress" == "localhost" ]]; then    
        #DEBUG:        
         if (( $DEBUG )); then echo "rsync type 1"; fi        
        #

        #echo -e "\nBACKUP: source = $s_userName@$sourceAddress:$fileOrDir    target = localhost:$targetDir/" >> "$backupInfoDir/$RSYNC_LOG"
        echo -e "\nBACKUP: source = $s_userName@$sourceAddress:$fileOrDir    target = $targetAddress:$targetDir/" >> "$backupInfoDir/$RSYNC_LOG"
        echo    "--------------------------------------------------------------------------------------------" >> "$backupInfoDir/$RSYNC_LOG"                
        rsync $prelimSwitches $delSwitch $statsSwitch --exclude-from=$ExcludeList --log-file="$backupInfoDir/$RSYNC_LOG" --link-dest="$targetDir/$(cat $backupInfoDir/time_before.txt)" -e "ssh -i $s_sshKey -p $s_sshPort -o StrictHostKeyChecking=no" "$s_userName@$sourceAddress:$fileOrDir" "$targetDir/$datetime/" 2>> "$backupInfoDir/$ERROR_LOG" 
        RSYNC1_EXIT_STATUS=$?

    # 2. from local source to local target (ie. data PUSHed from local source, to local target):
    elif [[ "$sourceAddress" == "localhost" ]] && [[ "$targetAddress" == "localhost" ]]; then    
        #DEBUG:
         if (( $DEBUG )); then echo "rsync type 2"; fi        
        #

        echo -e "\nBACKUP: source = $sourceAddress:$fileOrDir    target = $sourceAddress:$targetDir/" >> "$backupInfoDir/$RSYNC_LOG"
        echo    "--------------------------------------------------------------------------------" >> "$backupInfoDir/$RSYNC_LOG"        
        rsync $prelimSwitches $delSwitch $statsSwitch --exclude-from=$ExcludeList --log-file="$backupInfoDir/$RSYNC_LOG" --link-dest="$targetDir/$(cat $backupInfoDir/time_before.txt)" "$fileOrDir" "$targetDir/$datetime/" 2>> "$backupInfoDir/$ERROR_LOG"
        RSYNC1_EXIT_STATUS=$?
    
    # 3. from local source to remote target (ie. data PUSHed from local source, to remote target)
    elif [[ "$sourceAddress" == "localhost" ]] && [[ "$targetAddress" != "localhost" ]]; then        
        #DEBUG:
         if (( $DEBUG )); then echo "rsync type 3: sourceAddress = $sourceAddress, targetAddress = $targetAddress"; fi
        #

        echo -e "\nBACKUP: source = $sourceAddress:$fileOrDir    target = $t_userName@$targetAddress:$targetDir/" >> "$backupInfoDir/$RSYNC_LOG"
        echo    "--------------------------------------------------------------------------------------------" >> "$backupInfoDir/$RSYNC_LOG"               
        rsync $prelimSwitches $delSwitch $statsSwitch --exclude-from=$ExcludeList --log-file="$backupInfoDir/$RSYNC_LOG" --link-dest="$targetDir/$(cat $backupInfoDir/time_before.txt)" -e "ssh -i $t_sshKey -p $t_sshPort -o StrictHostKeyChecking=no" "$fileOrDir" "$t_userName@$targetAddress:$targetDir/$datetime/" 2>> "$backupInfoDir/$ERROR_LOG"
        RSYNC1_EXIT_STATUS=$?

    # 4. from remote source to remote target - THIS IS NOT ALLOWED! - terminate script w/ error message & log. 
    else
      echo -e "\nCRITICAL ERROR:  Backup from a remote host ($sourceAddress) to a remote host ($targetAddress) is not allowed." 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"
      echo "Script terminated." 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"             

      echo -e "$EMAIL_MESSAGE" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER

      #terminate script
      stopScriptRunFlag "$scriptRunFlag"
      (($DEBUG)) && printScriptRunStatus $scriptRunFlag && pressAnyKey      
      exit 1  
    fi

    #inc counter
    counter=$((counter+1))
done

if [[ $RSYNC1_EXIT_STATUS != 0 ]]; then
  echo -e "\nWARNING:  The backup script $0 has completed, but some data has either not been synced" 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"
  echo -e "or synced correctly to the target location.\n" 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"
  echo -e "$EMAIL_MESSAGE" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER
  #exit 1
fi

## RSYNC BACKUP LOG-FILEs TO TARGET DIRECTORY (and then delete local/temp log file)
#  --------------------------------------------------------------------------------
#  We use either secure copy or rsync to take the rsync & error logs and place it in the proper directory (i.e. under the $targetDir)
#
RSYNC2_EXIT_STATUS=1    #to record exit status to the rsync command  (default exit status is 1 (fail))
RSYNC3_EXIT_STATUS=1    #to record exit status to the rsync command  (default exit status is 1 (fail))

if [[ ( "$targetAddress" == "localhost" || "$targetAddress" == "$SERVER_IP" ) ]]; then     
    rsync -avzhP "$backupInfoDir/$RSYNC_LOG" "$targetDir/$datetime/$RSYNC_LOG" 2>> "$backupInfoDir/$ERROR_LOG"
    RSYNC2_EXIT_STATUS=$?

    rsync -avzhP "$backupInfoDir/$ERROR_LOG" "$targetDir/$datetime/$ERROR_LOG" 2>> "$backupInfoDir/$ERROR_LOG"
    RSYNC3_EXIT_STATUS=$?
else
    rsync -avzhP -e "ssh -i $t_sshKey -p $t_sshPort -o StrictHostKeyChecking=no" "$backupInfoDir/$RSYNC_LOG" "$t_userName@$targetAddress:$targetDir/$datetime/$RSYNC_LOG" 2>> "$backupInfoDir/$ERROR_LOG"
    RSYNC2_EXIT_STATUS=$?

    rsync -avzhP -e "ssh -i $t_sshKey -p $t_sshPort -o StrictHostKeyChecking=no" "$backupInfoDir/$ERROR_LOG" "$t_userName@$targetAddress:$targetDir/$datetime/$ERROR_LOG" 2>> "$backupInfoDir/$ERROR_LOG"
    RSYNC3_EXIT_STATUS=$?
fi

# check if exit status of previous rsync commands was succesful (0); wipe log-files under $backupInfoDir
if [[ ( ! $RSYNC2_EXIT_STATUS -eq 0 || ! $RSYNC3_EXIT_STATUS -eq 0 ) ]]; then
  echo -e "\nWARNING:  One or both rsync and error logs have not been transfered to the target host ($targetAddress) succesfully.\n" 2>&1 | tee -a "$backupInfoDir/$ERROR_LOG"  
  echo -e "$EMAIL_MESSAGE" | mail -s "$EMAIL_SUBJECT" $EMAIL_RECEIVER
  #exit 1
else
  rm "$backupInfoDir/$RSYNC_LOG"  
  rm "$backupInfoDir/$ERROR_LOG"
fi


##Exit the process with succesful (0) exit status value, after removing the script 'running' indicator.
echo -e "\n\nTerminating script..."
stopScriptRunFlag "$scriptRunFlag"
(($DEBUG)) && pressAnyKey
exit 0
