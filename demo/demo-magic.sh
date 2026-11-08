#!/usr/bin/env bash

###############################################################################
#
# demo-magic.sh
#
# Copyright (c) 2015 Paxton Hare
#
# This script lets you script demos in bash. It runs through your demo script when you press
# ENTER. It simulates typing and runs commands.
#
###############################################################################

# the speed to "type" the text
TYPE_SPEED="${TYPE_SPEED:-20}"

# no wait after "p" or "pe"
NO_WAIT="${NO_WAIT:-false}"

# if > 0, will pause for this amount of seconds before automatically proceeding with any p or pe
PROMPT_TIMEOUT=0

# don't show command number unless user specifies it
SHOW_CMD_NUMS=false

# Auto-detect non-TTY / CI environment:
# If stdin is not a terminal or NO_WAIT is requested, disable waiting, typing delays, and screen clears
if [[ ! -t 0 || "$NO_WAIT" == "true" || -n "$CI" || -n "$NON_INTERACTIVE" ]]; then
  NO_WAIT=true
  unset TYPE_SPEED
  clear() { :; }
fi

# handy color vars for pretty prompts
BLACK="\033[0;30m"
BLUE="\033[0;34m"
GREEN="\033[0;32m"
GREY="\033[0;90m"
CYAN="\033[0;36m"
RED="\033[0;31m"
PURPLE="\033[0;35m"
BROWN="\033[0;33m"
WHITE="\033[1;37m"
COLOR_RESET="\033[0m"

C_NUM=0

# prompt and command color which can be overriden
DEMO_PROMPT="$ "
DEMO_CMD_COLOR=$WHITE
DEMO_COMMENT_COLOR=$GREY

##
# prints the script usage
##
function usage() {
  echo -e ""
  echo -e "Usage: $0 [options]"
  echo -e ""
  echo -e "\tWhere options is one or more of:"
  echo -e "\t-h\tPrints Help text"
  echo -e "\t-d\tDebug mode. Disables simulated typing"
  echo -e "\t-n\tNo wait"
  echo -e "\t-w\tWaits max the given amount of seconds before proceeding with demo (e.g. '-w5')"
  echo -e ""
}

##
# wait for user to press ENTER
# if $PROMPT_TIMEOUT > 0 this will be used as the max time for proceeding automatically
##
function wait() {
  if [[ "$NO_WAIT" == "true" || ! -t 0 ]]; then
    return 0
  fi
  local key=""
  if [[ "$PROMPT_TIMEOUT" == "0" ]]; then
    read -rs -n 1 key || return 0
  else
    read -rst "$PROMPT_TIMEOUT" -n 1 key || return 0
  fi
  # If an escape sequence was initiated (e.g. Right Arrow or PageDown from a clicker), flush trailing bytes
  if [[ "$key" == $'\x1b' ]]; then
    read -rs -t 0.05 -n 4 _rest || true
  fi
}

##
# print command only. Useful for when you want to pretend to run a command
#
# takes 1 param - the string command to print
#
# usage: p "ls -l"
#
##
function type_out() {
  local text="$1"
  if [[ "$NO_WAIT" == "true" || -z "$TYPE_SPEED" || ! -t 0 ]]; then
    echo -e "$DEMO_CMD_COLOR$text$COLOR_RESET"
    return 0
  fi

  if command -v pv >/dev/null 2>&1; then
    echo -en "$DEMO_CMD_COLOR$text$COLOR_RESET" | pv -qL $[$TYPE_SPEED+(-2 + RANDOM%5)]
    echo ""
  else
    python3 -c "
import sys, time
text = sys.argv[1]
color = sys.argv[2]
reset = sys.argv[3]
delay = min(0.02, 1.2 / max(len(text), 1))
sys.stdout.write(color)
for ch in text:
    sys.stdout.write(ch)
    sys.stdout.flush()
    time.sleep(delay)
sys.stdout.write(reset + '\n')
sys.stdout.flush()
" "$text" "$DEMO_CMD_COLOR" "$COLOR_RESET"
  fi
}

function p() {
  # Comments print immediately without prompting or waiting
  if [[ -z "$1" || ${1:0:1} == "#" ]]; then
    echo -e "$DEMO_COMMENT_COLOR$1$COLOR_RESET"
    return 0
  fi

  # Render prompt for simulated commands
  local x="$DEMO_PROMPT"
  if $SHOW_CMD_NUMS; then
    printf "[$((++C_NUM))] $x"
  else
    printf "$x"
  fi

  type_out "$1"
}

##
# Prints and executes a command
#
# takes 1 parameter - the string command to run
#
# usage: pe "ls -l"
#
##
function pe() {
  # Wait once per execution block before typing and running
  if !($NO_WAIT); then
    wait
  fi

  p "$@"

  # execute the command
  eval "$@"
}

##
# Enters script into interactive mode
#
# and allows newly typed commands to be executed within the script
#
# usage : cmd
#
##
function cmd() {
  # render the prompt
  if [[ ! -t 0 || -z "$BASH" ]]; then
    x="$DEMO_PROMPT"
  else
    x=$(PS1="$DEMO_PROMPT" "$BASH" --norc -i </dev/null 2>&1 | sed -n '${s/^\(.*\)exit$/\1/p;}')
    [[ -z "$x" ]] && x="$DEMO_PROMPT"
  fi
  printf "$x\033[0m"
  read command
  eval "${command}"
}


function check_pv() {
  if ! command -v pv >/dev/null 2>&1; then
    unset TYPE_SPEED
  fi
}

check_pv
#
# handle some default params
# -h for help
# -d for disabling simulated typing
#
while getopts ":dhncw:" opt; do
  case $opt in
    h)
      usage
      exit 1
      ;;
    d)
      unset TYPE_SPEED
      ;;
    n)
      NO_WAIT=true
      ;;
    c)
      SHOW_CMD_NUMS=true
      ;;
    w)
      PROMPT_TIMEOUT=$OPTARG
      ;;
  esac
done
