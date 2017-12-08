#!/usr/bin/env bash
#
### Program Name: Bashellite
#
### Program Author: Cody Lee Cochran <Cody.L.Cochran@gmail.com>
### Program Contributors: Eric Lake <EricLake@Gmail.com>
#
### Program Purpose:
#   The purpose of this program is to create an automated method for pulling
#   package files from an upstream mirror on the internet, and exporting
#   the newly created local mirror to an external HDD for import to an "air-gapped"
#   network. The repo data retrieved from upstream repos is staged on a local mirror
#   that does have internet access, and is prepped for export on that local
#   mirror. The local mirror is also used to keep track of what has previously
#   been exported so that a diff can be run each time data is pulled from
#   the upstream repos. This is used to determine what gets exported from the
#   local staging mirror to the downstream air-gapped mirror. The exports are
#   then shipped via a read-only medium to the air-gapped network to prevent
#   leakage from the air-gapped network onto the internet-connected network.
#
################################################################################


################################################################################
### DEBUGGING OPTIONS ###
#########################
#
### This section is for toggling debugging on/off.
#
################################################################################
set +x # <- Debugging off
#set -x # <- Debugging on

################################################################################


################################################################################
### SIGNAL HANDLING  ###
#########################
#
### This section is for handling signals with traps.
#
################################################################################
trap "err Exiting..." SIGTERM SIGINT;

################################################################################


################################################################################
### FUNCTION DEFINITIONS ###
############################
#
### This section is for functions related to the command-line interface of
### the program, like usage messaging and parameter parsing.
#
################################################################################

# These functions are used to generate colored output msg is green, err is red.
msg() {
  echo -e "$(tput setaf 2)$*$(tput setaf 7)";
}

err() {
  echo -e "$(tput setaf 1)$*$(tput setaf 7)";
}

# This function ensures you are root and/or have sudo access.
Check_user() {
  if [[ "${EUID}" != "0" ]]; then
    err "This script must be run as root and/or with sudo.";
    exit 1;
  fi
}

# This function prints usage messaging to STDOUT when invoked.
Usage() {
  echo
  echo "Usage: $(basename ${0})"
  echo "       -m mirror_top-level_directory"
  echo "       [-h]"
  echo "       [-d]"
  echo "       [-r repository_name] | [-a]"
  echo
  echo "       Mandatory Parameter(s):"
  echo "       -m:  Sets the disk mirror top-level directory."
  echo "            Only absolute (full) paths are accepted!"
  echo
  echo "       Optional Parameter(s):"
  echo "       -h:  Prints this usage message."
  echo "       -d:  Dry-run mode. Pulls down a listing of the files and"
  echo "            directories it would download, and then exits."
  echo "       -r:  The repo name to sync."
  echo "       -a:  Mutually exclusive with -r option; sync all repos."
  echo
}

# This function parses the parameters passed over the command-line by the user.
Parse_parameters() {
  if [[ "${#}" = "0" ]]; then
    Usage;
    exit 1;
  fi
  unset mirror_tld;
  unset repo_name;
  unset dryrun;
  unset all_repos;
  while getopts ":m:r:ahd" passed_parameter; do
   case "${passed_parameter}" in
      m)
        if [[ "${OPTARG:0:1}" != "/" ]]; then
          Usage;
          err "\n!!! Absolute paths only, please; exiting.\n";
          exit 1;
        else
          mirror_tld="${OPTARG}";
          # Drops the last "/" from the value of mirror_tld to ensure uniformity for functions using it.
          # Note: as a side-effect, this effective prevents using just "/" as the value for mirror_tld.
          mirror_tld="${mirror_tld%\/}";
          # This santizes the directory name of spaces or any other undesired characters.
          mirror_tld="${mirror_tld//[^a-zA-Z1-9_-/]}";
        fi
        ;;
      r)
        # Sanitizes the directory name of spaces or any other undesired characters.
	repo_name="${OPTARG//[^a-zA-Z1-9_-/]}";
	;;
      d)
        dryrun="--dry-run";
        ;;
      a)
        all_repos="true"
        ;;
      h)
        Usage;
        exit 0;
        ;;
      *)
        Usage;
        err "\n!!! Invalid option passed to \"$(basename ${0})\"; exiting. See Usage below.\n";
        exit 1;
        ;;
    esac
  done
  shift $((OPTIND-1));

  # Exit if both -a and -r are passed and display usage
  if [[ ${all_repos} && ${repo_name} ]]; then
      Usage;
      err "\n!!!The flags -a and -r are mutually exclusive. Use one or the other; exiting.\n";
      exit 1;
  fi

  # If the mirror_tld is unset or null; then exit.
  # Since the last "/" was dropped in Parse_parameter,
  # If user passed "/" for mirror_tld value, it effectively becomes "" (null).
  if [[ ! -n "${mirror_tld}" ]]; then
    Usage;
    err "\n!!! Please set the desired location of the local mirror; exiting.\n";
    exit 1;
  fi
}

################################################################################

################################################################################
### FUNCTION DEFINITIONS ###
############################
#
### This section is for functions related to the main execution of the program.
#
################################################################################

# Ensuring _metadata/ subdirectory exists in user-passed ${mirror_tld}.
Validate_mirror_framework() {
    msg "Creating/validating directory for mirror...";
    mkdir -p ${mirror_tld}/_metadata;
}

# This function creates/validates the file/directory framework for the requested repo.
Validate_repo_framework() {
  if [[ -n "${repo_name}" ]]; then
    msg "Creating/validating directory and file structure for repo (${repo_name})...";
    mkdir -p ${mirror_tld}/_metadata/${repo_name}/;
    touch ${mirror_tld}/_metadata/${repo_name}/rsync_url.conf;
    touch ${mirror_tld}/_metadata/${repo_name}/repo_excludes.conf;
    touch ${mirror_tld}/_metadata/${repo_name}/web_url.conf;
    touch ${mirror_tld}/_metadata/${repo_name}/README.txt
    mkdir -p ${mirror_tld}/${repo_name}/;
    mkdir -p /var/log/bashellite/;
    chown root:root /var/log/bashellite;
  fi
}

# This function validates that a URL has been provided for the rsync repo.
Validate_repo_metadata() {
  msg "Validating repo (${repo_name}) metadata...";
  if [[ -s "${mirror_tld}/_metadata/${repo_name}/rsync_url.conf" ]]; then
    rsync_url="$(cat ${mirror_tld}/_metadata/${repo_name}/rsync_url.conf)";
  elif [[ -s "$(realpath $(dirname ${0}))/_metadata/${repo_name}/rsync_url.conf" ]]; then
    cp -f $(realpath $(dirname ${0}))/_metadata/${repo_name}/rsync_url.conf ${mirror_tld}/_metadata/${repo_name}/rsync_url.conf
    rsync_url="$(cat ${mirror_tld}/_metadata/${repo_name}/rsync_url.conf)";
  else
    echo "Please place the rsync mirror URL of the repo in:";
    echo " => ${mirror_tld}/_metadata/${repo_name}/rsync_url.conf";
    echo "Please place any desired excluded paths/files in:";
    echo " => ${mirror_tld}/_metadata/${repo_name}/repo_excludes.conf";
    exit 1;
  fi
}


# This function performs the actual sync of the repository
Sync_repository() {
  msg "Syncing from upstream mirror to local repo (${repo_name})...";
  rsync -avSLP ${rsync_url} \
    ${dryrun} \
    --exclude-from="${mirror_tld}/_metadata/${repo_name}/repo_excludes.conf" \
    --safe-links \
    --hard-links \
    --update \
    --links \
    --delete \
    --delete-before \
    --ignore-existing \
    --log-file="/var/log/bashellite/${repo_name}.$(date --iso-8601='seconds').log" \
    ${mirror_tld}/${repo_name}
}


################################################################################


################################################################################
### PROGRAM EXECUTION ###
#########################
### This section is for the execution of the previously defined functions.
################################################################################

Check_user;
Parse_parameters ${@};
Validate_mirror_framework;
if [[ "${all_repos}" == "true" ]]; then
  for repo_name in $(ls ${mirror_tld}/_metadata/); do
    msg "Performing requested sync tasks for repo (${repo_name})..."
    Validate_repo_framework \
    && Validate_repo_metadata \
    && Sync_repository;
  done
else
  msg "Performing requested sync tasks for repo (${repo_name})..."
  Validate_repo_framework \
  && Validate_repo_metadata \
  && Sync_repository;
fi

################################################################################

