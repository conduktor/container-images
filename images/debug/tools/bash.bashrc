# Installed as /etc/bash.bashrc by melange.yaml.
#
#
# shellcheck shell=bash

# Non-interactive shells (scripts, `bash -c`, the melange build itself) must see
# no side effects at all from this file.
case $- in
  *i*) ;;
  *) return ;;
esac

# --- prompt ------------------------------------------------------------------

# Colour only when there is a terminal that can take it. Dumb terminals and
# non-tty sessions get the plain form, so escape codes never end up pasted into
# a support ticket.
#
# Tests fd 2, not fd 1: bash writes the prompt to stderr, so an interactive shell
# with stdout redirected still prompts to the terminal and should still colour.
__cdk_colour() {
  [ -t 2 ] || return 1
  case "${TERM}" in
    ''|dumb) return 1 ;;
  esac
  return 0
}

if __cdk_colour; then
  # \[...\] wraps non-printing bytes; without it bash miscounts the line length
  # and readline corrupts long command lines when you edit them.
  if [ "$(id -u)" -eq 0 ]; then
    __cdk_user='\[\e[1;31m\]\u\[\e[0m\]'   # red: root, no UID match for attach
  else
    __cdk_user='\[\e[1;32m\]\u\[\e[0m\]'
  fi
  # \\$ , not \$ : inside double quotes bash eats the backslash, and PS1 would
  # end up with a literal `$` that never becomes `#` for root.
  PS1="${__cdk_user}\[\e[2m\]@\[\e[0m\]\[\e[1;36m\]debug\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\\$ "
else
  PS1='\u@debug:\w\$ '
fi
unset -f __cdk_colour

# `debug` rather than \h: in a sidecar the hostname is the *pod's*, so every
# container in the pod prompts identically and it is easy to forget which one
# you are typing into.

# --- history -----------------------------------------------------------------

# Kept in memory only. HOME is often read-only or absent here (the accounts are
# apko-created and /home/conduktor may not exist), and a debug session's history
# is not worth a write failure on every exit.
unset HISTFILE
HISTSIZE=5000
HISTCONTROL=ignoreboth        # no dupes, and `  cmd` stays out of history
shopt -s histappend checkwinsize

# --- a few conveniences ------------------------------------------------------

alias ll='ls -alF'
alias la='ls -A'

# Both name forms exist for the Kafka tools; `k` is neither, so it is safe.
alias k='kafka-topics.sh'

# The single most common thing to want, and easy to get wrong across a shared
# PID namespace.
cdk-pids() {
  ps -eo pid,user,args | awk 'NR==1 || /[j]ava/'
}
