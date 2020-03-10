#!/bin/bash
 #
#
# ----------------------------------------------------------------------
##FUNCTIONS:
# ----------
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
          exit 1
        fi;;
    # if any other number arguments received from caller:
    *)  echo -e "\nFATAL ERROR:  Incorrect number arguments received.  Terminating process."
        exit 1
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

##Function printUsage ()
 #	Prints to standard out the correct usage of this script.
 #	@param: 	none
 #	@returns:	exit status 0
 #
function printUsage () {  
    echo ""
    echo "Bad arguments!"
    echo ""
    echo "DESCRIPTION: "
    echo "  $0 retrieves the Process ID (pid) of the process matched by the give regular expression."
    echo ""        
    echo "SYNTAX: "
    echo "  $0 [--debug] [--help] <regexp>"
    echo ""
    echo "  where:"
    echo "      --regex     : regular expression by which to match a process (or processes)"
    echo "      --debug     : OPTIONAL:  interactive outputs & debugging."
    echo "      --help      : OPTIONAL:  prints to stdout this text."
    echo ""
  return 0
}

## ----------------------------------------------------------------------
##VARs  
 ERROR=1						#if not exactly 1 parameter (directory name) received, or any execution error occured
 SUCCESS=0
 EXIT_STATUS=$SUCCESS		#function return/exit status (default: success (0))     
 DEBUG_ON=0                  #flag to flip debug output (default: 0, off)
 
 REGEXP=""                  #regular expression by which to match for one or more processes
 PID=""                     #Process ID of matched process, if any
 SCRIPT_PID="$BASHPID"						#this scripts process ID number
 SCRIPT_PPID="$PPID"						  #this scripts direct parent process ID number
 #SCRIPT_PPIDs="$(parent_pids)"			#array containing this script's process ID, and all of its ancestor's PIDs (upto but excluding PID 1)
 declare -a SCRIPT_PPIDs					#(default unset) array containing this script's process ID, and all of its ancestor's PIDs (upto but excluding PID 1)		
 parent_pids SCRIPT_PPIDs				#passing name of array to function where it can be set
 SCRIPT_TOPLEVEL_PPID="$(top_level_parent_pid)"			#this script's top-level parent process ID number (ie. highest ancestor PID number, just before 1 (/sbin/init))
 bold=$(tput bold)          #format font in output text to bold
 normal=$(tput sgr0)        #return to previous font
#

# individually loop through every function parameter ($1,$2,... $n), assigning parameters received to VARs    
for i in "$@"; do                                                                   
    if [[ $i == "--debug" ]]; then DEBUG_ON=1    
    elif [[ $i == "--help" ]]; then printUsage; EXIT_STATUS=$ERROR; exit $EXIT_STATUS
    elif [[ $i != "--debug" && $i != "--help" ]]; then REGEXP=$i
    else 
        printUsage
        EXIT_STATUS=$ERROR
        exit $EXIT_STATUS
    fi
done

##DEBUG: 
 if (( $DEBUG_ON )); then
    echo ""
    echo "DEBUG:  DEBUG_ON = $DEBUG_ON"
    echo "DEBUG:  SCRIPT_PID = $SCRIPT_PID"
    echo "DEBUG:  SCRIPT_PPID = $SCRIPT_PPID"
    echo "DEBUG:  SCRIPT_TOPLEVEL_PPID = $SCRIPT_TOPLEVEL_PPID"        
    echo "DEBUG:  REGEXP = $REGEXP"
    echo ""
    read -p "DEBUG: Press [Enter] key to continue..." key  
    echo ""
 fi
# e/o debug

##OPTION 1) FOR INCREMENTAL BACKUPs
declare -a PIDarray=$(ps -afx -o pid,cmd | grep -Ei "$REGEXP" | grep -Evi "($SCRIPT_PID|$SCRIPT_PPID|SCRIPT_TOPLEVEL_PPID|color|vscode|grep|ls|watch|nano)" | awk '{ print $1 }')
			# where: 
			 #		ps -afx -o pid,cmd			(echoes all processes showing process ID & command)
			 # 		|							(pipe output to next command)
			 # 		grep -i "$regex"			(match input to case-insesitive (-i) pattern in regex)
			 # 		|							(pipe output to next command)
			 #		 grep -v "color"			(exclude lines (-v) in input matching case-insesitive (-i) pattern of string 'color')
			 # 		|							(pipe output to next command)
			 # 		sed -n "1p"					(stream editor: print (p) to console, from input received, only the first (1) line) 
			 # 		|							(pipe output to next command)
			 # 		awk '{ print $1 }'			(awk: print (echo to console) from input received, only the first variable (white-space delimited) - i.e. PID)
			 #
			 # alternative syntax (would also work):
			 #		PIDarray=( $(ps -afx -o pid,cmd | grep -v 'color' | grep -E 'full_backup_PULL-version_v1.282.sh' | awk '{ print $1 }') )
            #

##DEBUG:
 if (( $DEBUG_ON )); then 
    echo -e "\nDEBUG:	${#PIDarray[@]} elements in array PIDarray:"        #echo -e "\nDEBUG:	number of elements in 0th PIDarray element: ${#PIDarray[0]}\n"
    for e in ${PIDarray[@]}; do echo "$e"; done 
    echo ""
    read -p   "DEBUG: Press [Enter] key to continue..." key 
    echo ""
 fi
#
## DEBUG:
 if (( $DEBUG_ON )); then 
    echo -e "\nDEBUG:	${#SCRIPT_PPIDs[@]} elements in array SCRIPT_PPIDs:"
    for f in ${SCRIPT_PPIDs[@]}; do echo "$f"; done
    echo ""
    read -p   "DEBUG: Press [Enter] key to continue..." key 
    echo ""
 fi
#

exit $EXIT_STATUS