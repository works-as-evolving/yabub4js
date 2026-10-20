#!/bin/bash
###############################################################################
# Copyright (C) 2026 BitCtrl Systems GmbH
#
# yabub4js.sh - Yet Another Blissfully Unaware Bundler For JavaScript
#
# A small and almost dependency-free JavaScript bundler written in Bash.
#
# Dependencies:
#   - sed, grep, tr
#   - tee
#   - realpath
#   - git
#
# @author:  Daniel Hammerschmidt <daniel.hammerschmidt@bitctrl.de>
# @version: 0.1.0-20264271 # (format: YYYYWWDN)
###############################################################################
#
# This is intentionally not a JavaScript parser.
#
# Supported imports:
#   import * as ns from 'module';
#   import { a, b as c } from 'module';
#
# Assumptions:
#   - module specifiers do not contain commas, semicolons, whitespace, quotes or asterisks
#   - import declarations are syntactically valid
#   - dynamic imports are not supported
#   - default imports are not supported
#
# Import URLs may contain a URL fragment used as a bundler directive:
#
#   import './module.mjs#early'
#
# The fragment is ignored when resolving the module on disk and is
# interpreted exclusively by the bundler.
#
### ENTRYPOINT ###
#
# If source directory is given as the first argument and
# ENTRYPOINT starts with "/" or ".", it is resolved as specified.
#
# Otherwise ENTRYPOINT is resolved relative to SOURCE_DIRECTORY.
#
# Examples:
#
#   yab4js.sh ./src svc/dt42-svc.mjs
#   yab4js.sh ./src mon/dt42-mon.mjs
#
#   yab4js.sh ./src ./src/svc/dt42-svc.mjs
#   yab4js.sh ./src ../other/main.mjs
#   yab4js.sh ./src /tmp/main.mjs
#
#   curl -sf https://works-as-evolved.github.io/yab4js/yab4js.sh \
#     | bash -s ./src svc/dt42-svc.mjs ./dist/dt42-svc.mjs
#
#####
#
# All modules are fed into the same scope, be aware of conflicting
# top-level identifiers and side-effects.
#
##### NOTES #####
# modified files: { git ls-files -d src/; git ls-files -m src/; } | uniq -c | grep '^[[:space:]]*1[[:space:]]'
# commit id: git rev-parse HEAD

set -euo pipefail

: "${YABUB4JS_LOG_TAG:=yabub4js}"

trap "code=\$?; log '^%Exiting with code %d' \${code}; exit \${code}" EXIT

declare -A node_named_imports
declare -A node_namespace_imports
declare -A local_named_imports
declare -A local_namespace_imports
declare -A local_modules

SEMICOLON=';'

_head=''
_foot=''
_version=''
printf -v _date '%(%FT%T%z(%Z))T' -1
_date=${_date/WEDT/CEST}
TZ=Z printf -v _build '%(%G%V%u)T.%d' -1 $(( EPOCHSECONDS % 86400))
_sha1sum='da39a3ee5e6b4b0d3255bfef95601890afd80709'
declare -A _feeds

function normalize_imports {
  sed -nE '
    /^import/,/from[[:space:]]*["'"'"'][^"'"'"']*["'"'"']/{
      # surround strings with spaces and convert double to single quotes
      s/"([^"]*)"|'"'"'([^'"'"']*)'"'"'/ '"'"'\1\2'"'"' /g
      # split multi-statement lines
      s/'${SEMICOLON}'[[:space:]]*/'${SEMICOLON}'\n/g
      p
    }
  ' | tee | sed -nE '
    /^import[[:space:]]*\*[[:space:]]*as[[:space:]]{1,}[^[:space:]]{1,}[[:space:]]{1,}from[[:space:]]{1,}([^'${SEMICOLON}']{3,})'${SEMICOLON}'?[[:space:]]*$/{
      ### s/^[[:space:]]*import[[:space:]]*/\/* namespace *\/ import /
      s/t[[:space:]]*\*[[:space:]]*a/t * a/
      s/[[:space:]](as|from)[[:space:]]/'${SEMICOLON}'\1'${SEMICOLON}'/g
      #s/$/'${SEMICOLON}'/
      p
    }
    /^import[[:space:]]*\{[[:space:]]*[^'${SEMICOLON}'}]*[[:space:]]*\}[[:space:]]*from[[:space:]]*[^'${SEMICOLON}']*'${SEMICOLON}'?[[:space:]]*$/{
      ### s/^[[:space:]]*import[[:space:]]*/\/* single-line-named *\/ import /
      s/\{/{\n/
      s/,/,\n/g
      s/\}/,\n}/
      s/[[:space:]]{1,}as[[:space:]]{1,}/'${SEMICOLON}'as'${SEMICOLON}'/g # escape spaces around as
      s/\}[[:space:]]*from[[:space:]]{1,}/}'${SEMICOLON}'from'${SEMICOLON}'/ # escape spaces around from
      s/$/'${SEMICOLON}'/
      p
    }
    /^import[[:space:]]*\{[^\}]*$/,/^[^{]*\}[[:space:]]*from[[:space:]]*[^'${SEMICOLON}']*'${SEMICOLON}'?[[:space:]]*$/{
      ### s/^[[:space:]]*import[[:space:]]*/\/* multi-line-named *\/ import /
      /\/\//d # delete line-comments
      s/[[:space:]]{1,}as[[:space:]]{1,}/'${SEMICOLON}'as'${SEMICOLON}'/g # escape spaces around as
      s/(from[^{}]*)$/\1'${SEMICOLON}'/ # append semicolon
      s/\}[[:space:]]*from[[:space:]]{1,}/}'${SEMICOLON}'from'${SEMICOLON}'/ # escape spaces around from
      p
    }
  ' | tr -d '[:space:]' | tee | sed -nE '
    s/(^|'${SEMICOLON}')(\/\*[^*]*\*\/)?(import)/\1\2\3 /g
    s/'${SEMICOLON}'(as|from)'${SEMICOLON}'/ \1 /g # restore spaces
    s/\{/{ /g; s/,*\}/ }/g; s/,/, /g # insert spaces
    s/'${SEMICOLON}'{1,}/'${SEMICOLON}'\n/g # separate statements
    p
  ' | tee
}

function process_directives() {
  ret=0
  log '.%Process %d %s: %s' ${#directives[@]} "$( pluralize 'directive' ${#directives[@]} )" "$( join_tokens ', ' ' and ' "${directives[@]@Q}" )"
  for directive in "${directives[@]}"; do
    case "${directive}" in
      head|foot) {
        ret=1
        name=_${directive}
        [[ -z "${!name}" ]] || { log '.%Ignore repeated %s directive' "${directive@Q}"; continue; }
        declare -g "${name}"="$( realpath -e --relative-to "${srcdir}" "${module##*/}" )"
        log '.%Using %s from %s' "${directive@Q}" "${!name@Q}"
      };;
      early) {
        log '.%Add module %s to early feeds' "${module@Q}"
        _feeds[:early]+=" ${module}"
        :
      };;
      version|version=*) {
        if [[ ${directive} == 'version' ]]; then
          identifier=${symbols[0]}
          identifier=${identifier%"${SEMICOLON}as${SEMICOLON}"*}
        else
          identifier=${directive#*=}
          directive=${directive%%=*}
        fi
        name=_${directive}
        [[ -z "${!name}" ]] || { log '.%Ignore repeated %s directive' "${directive@Q}"; continue; }
        read -r "${name?}" < <(
          sed -nE '
            /^(export[[:space:]]{1,})?(const|var)[[:space:]]{1,}'"${identifier}"'[[:space:]]*=/{
              s/.*=[[:space:]]*("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^'${SEMICOLON}']*))'${SEMICOLON}'?$/\2\3\4/p
              q0
            }
            $ q1
          ' "${srcdir}/${module}"
        ) || panic 1 'Cannot extract version from identifier %s in module %s' "${identifier@Q}" "${module@Q}"
        log '.%Using version %s from identifier %s in module %s' "${!name@Q}" "${identifier@Q}" "${module@Q}"
      };;
      external|closure) { # TODO: directives external, closure
        log '.%Directive %s is not implemented yet' "${directive@Q}"
      };;
      *) {
        log '.%Ignore unknown directive %s for module %s' "${directive@Q}" "${module@Q}"
      }
    esac
  done
  return ${ret}
}

function resolve_imports() {
  local tmp tokens module symbols name spec
  # local key
  # key="$( realpath -e --relative-to "${srcdir}" "${PWD}/${1}" )"

  log '>%Scanning file "%s" for imports ...' "$( realpath -e --relative-to "${srcdir}" "${1}" )"

  while read -ra tokens; do
    case ${tokens[1]} in
      "*") {
        spec=${tokens[5]}
        symbols=( "${tokens[1]}" )
      };;
      "{") {
        spec=${tokens[-1]}
        tmp="${tokens[*]:2:$((${#tokens[*]} - 5))}"
        tmp="${tmp// as /${SEMICOLON}as${SEMICOLON}}"
        tmp="${tmp//, /,}"
        IFS=',' read -ra symbols <<<"${tmp}"
      };;
    esac

    spec=${spec#*\'}
    spec=${spec%\'*}
    tmp=${spec}
    module=${spec%'#'*}
    tmp=${tmp#"${module}"}
    module=${module%'?'*}
    tmp=${tmp//&/ }
    read -ra directives <<<"${tmp#'#'}"
    case "${module}" in
      node:*) {
        :
      };;
      http:*|https:*) {
        :
      };;
      *) {
        [[ ${module} == *.[cm]js || ${module} == *.js || -f ${module} ]] || module="${module}.js"
        module=$( realpath --relative-to "${srcdir}" "${PWD}/${module}" )
        :
      }
    esac

    log '>%Import Module %s (%s) with %d %s: %s' \
      "${module@Q}" \
      "${spec}" \
      "${#symbols[@]}" \
      "$( pluralize 'symbol' ${#symbols[@]} )" \
      "$( join_tokens ', ' ' and ' "${symbols[@]@Q}" )"

    if [[ ${tokens[1]} == '*' ]]; then
      case ${spec} in
        node:*) {
          name=${tokens[3]}
          node_namespace_imports[${module}]+=" ${name}"
        };;
        https:*|http:*) {
          panic 1 'Imports over HTTP are not supported yet'
        };;
        .*) {
          # TODO: check if module is inside source directory
          # log ">%>>>"
          pushd "${srcdir}//${module%/*}" > /dev/null
          feed=1
          (( ${#directives[@]} )) && { process_directives || feed=0; }
          popd > /dev/null
          # log "<%<<<"
          name=${tokens[3]}
          local_namespace_imports[${module}]+=" ${name}"
          local_modules["${module}"]=1
          (( feed && !${_feeds[${module}]:=0} )) && {
            _feeds[:all]+=" ${module}"
            _feeds[${module}]=1
          }
        };;
        *) {
          panic 1 'node_modules not supported yet.'
        };;
      esac
    else
      case ${spec} in
        node:*) {
          node_named_imports[${module}]+=" ${symbols[*]}"
        };;
        https:*|http:*) {
          panic 1 'Imports over HTTP are not supported yet'
        };;
        .*) {
          feed=1
          (( ${#directives[@]} )) && { process_directives || feed=0; }
          (( ${#symbols[@]} )) || continue; # TODO: WTF?
          # TODO: give foobar a name or get rif of it
          foobar="${local_named_imports[${module}]:-}"
          local_named_imports[${module}]+=" ${symbols[*]}"
          if [[ -z "${foobar}" ]]; then
            local_modules["${module}"]=1
            (( feed && !${_feeds[${module}]:=0} )) && {
              _feeds[:all]+=" ${module}"
              _feeds[${module}]=1
            }
            pushd "${srcdir}//${module%/*}" > /dev/null
            resolve_imports "${module##*/}"
            popd > /dev/null
          fi
        };;
        *) {
          panic 1 'node_modules not supported yet.'
        };;
      esac
    fi
    log '<.'
  done < <( normalize_imports < "${1}" )

  log '<Done'
}

function print_imports() {
  newblock=0
  modules="${!node_namespace_imports[*]}"
  while read -r module; do
    if [[ -n ${module} ]]; then newblock=1; else continue; fi
    namespaces="${node_namespace_imports[${module}]}"
    while read -r namespace; do
      [[ -n ${namespace} ]] || continue
      echo "import * as ${namespace} from '${module}';"
    done <<<"$( IFS=$'\n' sort -u <<<"${namespaces// /$'\n'}" )"
  done <<<"$( IFS=$'\n' sort <<<"${modules// /$'\n'}" )"

  modules="${!node_named_imports[*]}"
  while read -r module; do
    if [[ -n ${module} ]]; then newblock=1; else continue; fi
    symbols2="${node_named_imports[${module}]}"
    symbols2=$( sort -u <<<"${symbols2// /$'\n'}" )
    symbols2=${symbols2//$'\n'/, }
    symbols2=${symbols2//${SEMICOLON}as${SEMICOLON}/ as }
    echo "import { ${symbols2:2} } from '${module}';"
  done <<<"$( IFS=$'\n' sort <<<"${modules// /$'\n'}" )"

  modules="${!local_namespace_imports[*]}"
  while read -r module; do
    (( newblock )) && { newblock=0; echo; }
    namespaces="${local_namespace_imports[${module}]}"
    while read -r namespace; do
      [[ -n ${namespace} ]] || continue
      echo "// import * as ${namespace} from '${module}';"
    done <<<"$( IFS=$'\n' sort -u <<<"${namespaces// /$'\n'}" )"
  done <<<"$( IFS=$'\n' sort <<<"${modules// /$'\n'}" )"

  modules="${!local_named_imports[*]}"
  while read -r module; do
    (( newblock )) && { newblock=0; echo; }
    symbols2="${local_named_imports[${module}]}"
    symbols2=$( sort -u <<<"${symbols2// /$'\n'}" )
    symbols2=${symbols2//$'\n'/, }
    symbols2=${symbols2//${SEMICOLON}as${SEMICOLON}/ as }
    echo "// import { ${symbols2:2} } from '${module}';"
  done <<<"$( IFS=$'\n' sort <<<"${modules// /$'\n'}" )"
}

function feed_head() {
  file="${1}"
  sed -E '
    /\/\*\*/,/\*\//{
      s/\{:VERSION:\}/'"${_version}"'/
      s/\{:BUILD:\}/'"${_build}"'/
      s/\{:DATE:\}/'"${_date}"'/
      s/\{:COMMIT:\}/da39a3ee5e6b4b0d3255bfef95601890afd80709/
    }
  ' "${file}"
}

function feed_foot() {
  file="${1}"
  sed -E '
    /\/\*\*/,/\*\//{
      s/\{:SHA1SUM:\}/'"${_sha1sum}"'/
    }
  ' "${file}"
}

function feed_module() {
  module="${1}"
  log ".%Feed file %s" "${module@Q}"
  echo
  echo "/** @feed ${module} */"
  sed -nE '
    /\/\*\*/,/\*\//{p}
    /\*\//{q0}
  ' "${module}"
  while read -r; do
    echo "// ${REPLY}"
  done < <( normalize_imports < "${module}" )
  import_end=0
  while read -r; do
    [[ -n ${REPLY} ]] || continue
    import_end=${REPLY%%:*}
  done < <(
    grep -nE '^[^*/"'"'"';]*[[:space:]]{1,}from[[:space:]]' "${module}" \
    || grep -nE '^[[:space:]]*import[[:space:]]{1,}\*[[:space:]]' "${module}" \
    || grep -m1 -nE '^[[:space:]]*\*/[[:space:]]*$' "${module}"
  )
  # shellcheck disable=SC2016 # it's not an expression, it's a sed command
  sed -nE $(( import_end + 1 ))',${p}' "${module}"
}

# Entry point
function main() { { :x:off; } 2>&-
  { :x:on; } 2>&-; parse_command_line "${@}"

  log . "srcdir:     ${srcdir}"
  log . "entrypoint: ${entrypoint}"
  log . "outfile:    ${outfile}"

  main_module=${entrypoint#"${srcdir}/"}
  _feeds[:all]="${main_module}"
  _feeds[${main_module}]=1

  { pushd "${entrypoint%/*}"; } > /dev/null
  resolve_imports "./${entrypoint##*/}"
  { popd; } > /dev/null

  log - < <( print_imports )

  { pushd "${srcdir}"; } > /dev/null

  real_outfile="${outfile}"
  if [[ ${outfile} != /dev/stdout ]]; then
    outfile="${outfile%/*}/.${outfile##*/}~"
  fi

  {
    [[ -n ${_head} ]] && feed_head "${_head}"

    print_imports

    for feed in ${_feeds[:early]}; do
      (( ${_feeds[${feed}]:-0} )) || continue
      _feeds[${feed}]=0
      feed_module "${feed}"
    done

    for feed in ${_feeds[:all]}; do
      (( ${_feeds[${feed}]:-0} )) || continue
      _feeds[${feed}]=0
      feed_module "${feed}"
    done
  } > "${outfile}"

  if [[ ${real_outfile} != "${outfile}" ]]; then
    if [[ -n ${_foot} ]]; then
      read -r _sha1sum _ < <( sed -E 's/\r$//' < "${outfile}" | sha1sum.exe )
      feed_foot "${_foot}" >> "${outfile}"
    fi
    mv "${outfile}" "${real_outfile}"
  fi

  { popd; } > /dev/null
}

# Returns word or words depending on count.
#
# Usage:
#   pluralize file 1          -> file
#   pluralize file 2          -> files
#   pluralize person 2 people -> people
function pluralize() {
  if (( ${2} == 1 )); then
    echo "${1}"
  else
    echo "${3:-${1}s}"
  fi
}

# Joins tokens using separate delimiters for intermediate and final items.
#
# Usage:
#   join_tokens ', ' ' and ' a            -> a
#   join_tokens ', ' ' and ' a b          -> a and b
#   join_tokens ', ' ' and ' a b c        -> a, b and c
#   join_tokens ', ' ', and ' a b c d     -> a, b, c, and d
#
# Parameters:
#   $1  Separator between all but the last two tokens.
#   $2  Separator between the last two tokens.
#   $@  Tokens to join.
function join_tokens() {
  local sep="${1}"; shift
  local last="${1}"; shift
  (( $# == 0 )) && printf '' && return
  (( $# == 1 )) && printf '%s' "${@:1}" && return
  (( $# > 2 )) && printf "%s${sep}" "${@:1:(($#-2))}"
  printf "%s${last}%s\n" "${@:(($#-1))}"
}

function parse_command_line() { { :x:off; } 2>&-;
  while (( ${#} )); do
    case "${1}" in
      --) shift; break;;
      -*) panic 1 'unknown command line option "%s"' "${1}";;
      *) break;;
    esac
  done

  # input
  if [[ -d ${1} ]]; then
    srcdir=$( realpath "${1}" )
    shift
    if (( !${#} )) || [[ ${1} == '-' ]]; then
      entrypoint=/dev/stdin
      (( ${#} )) && shift
    else
      case "${1}" in
        # absolute or relative to current working directory
        '.'*|'/'*) {
          entrypoint=$( realpath -m "${1}" )
        };;
        # relative to source directory
        *) {
          entrypoint=$( realpath -m "${srcdir}/${1}" )
        };;
      esac
      shift
    fi
  elif [[ -f ${1} ]]; then
    entrypoint=$( realpath "${1}" )
    shift
    srcdir=${entrypoint%/*}
  fi

  # output
  if (( !${#} )) || [[ ${1} == '-' ]]; then
    outfile=/dev/stdout
    (( ${#} )) && shift
  else
    outfile=$( realpath -m "${1}" )
    shift
  fi

  (( ${#} == 0 )) || panic 1 'Unexpected extra arguments %s' "${*@Q}"

  [[ ${entrypoint} == ${srcdir}/* || ${entrypoint} == /dev/stdin ]] || panic 1 'Entry point "%s" is out of source directory "%s"' "${entrypoint}" "${srcdir}"
  [[ -f ${entrypoint} || ${entrypoint} == /dev/stdin ]] || panic 1 'Entry point "%s" does not exist' "${entrypoint}"
  [[ -d ${outfile%/*} || ${outfile} == /dev/stdout ]] || panic 1 'Output directory "%s" does not exist' "${outfile%/*}"
  [[ ${outfile} != ${srcdir}/* || ${outfile} == /dev/stdout ]] || panic 1 'Output file is inside source directory "%s"' "${srcdir}"
}

##### panic() #####
# Exit the program. The first argument is used as the exit code.
# Remaining arguments, if any, are passed to log().
function panic() { { set +x; } 2>&-
  local code=${1}; shift
  (( ${#} )) && log '^' "${@}"
  exit "${code}"
}

##### log() #####
# Bash xtrace is temporarily disabled while logging.
# Indentation modifiers:
#   .  Print at current indentation level.
#   >  Print and then increase indentation.
#   <  Decrease indentation and then print.
#   ^  Print without indentation.
#   0  Reset indentation and then print.
# Message formatting:
#   The first word is treated as a printf format string only if it
#   starts with '%'. Otherwise all arguments are treated as literal
#   words and joined with spaces.
# Indentation modifiers may be combined with the first word of a message.
# Similar to SMTP dot-stuffing, the leading dot of a message following
# an indentation modifier is removed.
# With '-' as the only argument, lines are read from stdin and printed
# using the same timestamp, tag, and indentation level.
# Examples:
#   log                        # Print only a timestamp.
#   log . Hello world          # Hello world
#   log . '%Hello %s' world    # Hello world
#   log .%%s test              # test
#   log \>Entering build step
#   log \<Done
#   log .             # Print a dot or another single-character message.
#   log 0 .           # Only adjust indentation.
#   log . ..          # Adjust indentation and print a dot.
#   log - < <( < /etc/shadow )
function log() { { local xtrace=0; [[ ${SHELLOPTS/xtrace/} == "${SHELLOPTS}" ]] || { xtrace=1; set +x; }; } 2>&-
  local words fmt msg mod ind ms pre; : "${__log_indent:=}"
  if (( ${#} == 1 )) && [[ ${1} == '-' ]]; then
    ms=${EPOCHREALTIME#*.}00
    printf -v pre '%(%T)T.%s [%d/%s] %s' -1 "${ms:0:3}" $$ "${YABUB4JS_LOG_TAG:=${0##*/}}" "${__log_indent}"
    while read -r; do
      printf '%s%s\n' "${pre}" "${REPLY}" > /dev/stderr
    done
  else
    if (( ${#} == 0 )); then
      mod='.'; words=( '' )
    elif (( ${#1} == 1 )); then
      if (( ${#} == 1 )); then
        mod='.'; words=( '%%c' "${1}" )
      else
        mod=${1}; words=( "${@:2}" )
      fi
    else
      mod="${1:0:1}"; words=( "${1:1}" "${@:2}" )
    fi
    case "${mod}" in
      '.') ind="${__log_indent}";;
      '^') ind='';;
      '>') ind="${__log_indent}"; __log_indent+='  ';;
      '<') ind=${__log_indent:0:$(( ${#__log_indent} > 1 ? -2 : 0 ))}; __log_indent="${ind}";;
      '0') ind=''; __log_indent="${ind}";;
      *) ind=""; words=( '%Invalid invocation: %s %s' "${FUNCNAME[0]}" "${*@Q}" );;
    esac
    if (( ${#words[@]} > 1 )) || [[ ${words[0]} != . ]]; then
      if [[ ${words[0]:0:1} == '%' ]]; then
        fmt=${words[0]:1}
        set -- "${words[@]:1}"
      else
        fmt='%s'
        if [[ ${words[0]:0:1} == . ]]; then
          set -- "${words[0]:1}" "${words[*]:1}"
        else
          set -- "${words[*]}"
        fi
      fi
      [[ ${fmt} == . ]] && return || :
      ms=${EPOCHREALTIME#*.}00
      # shellcheck disable=SC2059 # the format string is intentionally given as argument
      printf -v msg -- "${fmt#.}" "${@}"
      printf '%(%T)T.%s [%d/%s] %s%s\n' -1 "${ms:0:3}" $$ "${YABUB4JS_LOG_TAG:=${0##*/}}" "${ind}" "${msg}" > /dev/stderr
    fi
  fi
  (( xtrace )) && set -x || :
}

# Tracing levels:
#   TRACE  - Log script flow and selected operations.
#   XTRACE - Enable Bash xtrace (set -x).
# TRACE is enabled by default.
# Set TRACE and XTRACE to empty strings to suppress all tracing output.
if [[ -z ${YABUB4JS_TRACE=}${YABUB4JS_XTRACE=} ]]; then
  function :x:on() { :; }; function :x:off() { :; };
else
  # Usage: { :x:on; } 2>&-; { :x:off; } 2>&-
  function :x:on() { [[ -n ${YABUB4JS_TRACE}${YABUB4JS_XTRACE} ]] && set -x || :; }
  function :x:off() { [[ -z ${YABUB4JS_XTRACE} || ${1:-} == 'force' ]] && set +x || :; }
fi

log ^ Started; { :x:on; } 2>&-; main "${@}"; exit
