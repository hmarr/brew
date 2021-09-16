#!/bin/bash

onoe() {
  echo "$*" >&2
}

odie() {
  onoe "$@"
  exit 1
}

# HOMEBREW_PREFIX is set by extend/ENV/super.rb
# shellcheck disable=SC2154
if [[ -z "${HOMEBREW_PREFIX}" ]]
then
  odie "${0##*/}: This program is internal and must be run via brew."
fi

# HOMEBREW_PREFIX is set by extend/ENV/super.rb
# shellcheck disable=SC2154
SHFMT="${HOMEBREW_PREFIX}/opt/shfmt/bin/shfmt"

if [[ ! -x "${SHFMT}" ]]
then
  odie "${0##*/}: Please install shfmt by running \`brew install shfmt\`."
fi

if [[ ! -x "$(command -v diff)" ]]
then
  odie "${0##*/}: Please install diff by running \`brew install diffutils\`."
fi

SHFMT_ARGS=()
INPLACE=''
while [[ $# -gt 0 ]]
do
  arg="$1"
  if [[ "${arg}" == "--" ]]
  then
    shift
    break
  fi
  if [[ "${arg}" == "-w" ]]
  then
    shift
    INPLACE=1
    continue
  fi
  SHFMT_ARGS+=("${arg}")
  shift
done

FILES=()
for file in "$@"
do
  if [[ -f "${file}" ]]
  then
    if [[ -w "${file}" ]]
    then
      FILES+=("${file}")
    else
      onoe "${0##*/}: File \"${file}\" is not writable."
    fi
  else
    onoe "${0##*/}: File \"${file}\" does not exist."
    exit 1
  fi
done

if [[ "${#FILES[@]}" == 0 ]]
then
  exit
fi

###
### Custom shell script styling
###

# Check pattern:
# '^\t+'
#
# Replace tabs with 2 spaces instead
#
no_tabs() {
  local file="$1"
  local tempfile="$2"
  local line
  local num=0
  local retcode=0
  local regex_pos='^[[:space:]]+'
  local regex_neg='^ +'

  while IFS='' read -r line
  do
    num="$((num + 1))"
    if [[ "${line}" =~ ${regex_pos} && ! "${line}" =~ ${regex_neg} ]]
    then
      onoe "Indent by tab detected at \"${file}\", line ${num}."
      retcode=1
    fi
  done <"${file}"
  return "${retcode}"
}

# Check pattern:
# for var in ... \
#            ...; do
#
# Use the followings instead (keep for statements only one line):
#   ARRAY=(
#     ...
#   )
#   for var in "${ARRAY[@]}"
#   do
#
no_multiline_for_statements() {
  local file="$1"
  local tempfile="$2"
  local line
  local num=0
  local retcode=0
  local regex='^ *for [_[:alnum:]]+ in .*\\$'

  while IFS='' read -r line
  do
    num="$((num + 1))"
    if [[ "${line}" =~ ${regex} ]]
    then
      onoe "Multiline for statement detected at \"${file}\", line ${num}."
      cat >&2 <<EOMSG
Use the followings instead (keep for statements only one line):
  ARRAY=(
    ...
  )
  for var in "\${ARRAY[@]}"
  do
    ...
  done
EOMSG
      retcode=1
    fi
  done <"${file}"
  return "${retcode}"
}

# Check pattern:
# IFS=$'\n'
#
# Use the followings instead:
#   while IFS='' read -r line
#   do
#     ...
#   done < <(command)
#
no_IFS_newline() {
  local file="$1"
  local tempfile="$2"
  local line
  local num=0
  local retcode=0
  local regex="^[^#]*IFS=\\\$'\\\\n'"

  while IFS='' read -r line
  do
    num="$((num + 1))"
    if [[ "${line}" =~ ${regex} ]]
    then
      onoe "Pattern \`IFS=\$'\\n'\` detected at \"${file}\", line ${num}."
      cat >&2 <<EOMSG
Use the followings instead:
  while IFS='' read -r line
  do
    ...
  done < <(command)
EOMSG
      retcode=1
    fi
  done <"${file}"
  return "${retcode}"
}

# Combine all forbidden styles
no_forbiddens() {
  local file="$1"
  local tempfile="$2"

  no_tabs "${file}" "${tempfile}" || return 1
  no_multiline_for_statements "${file}" "${tempfile}" || return 1
  no_IFS_newline "${file}" "${tempfile}" || return 1
}

# Align multiline if condition (indent with 3 spaces or 6 spaces (start with "-"))
# before:                   after:
#   if [[ ... ]] ||           if [[ ... ]] ||
#     [[ ... ]]                  [[ ... ]]
#   then                      then
#
# before:                   after:
#   if [[ -n ... || \         if [[ -n ... || \
#     -n ... ]]                     -n ... ]]
#   then                      then
#
align_multiline_if_condition() {
  local multiline_if_begin_regex='^( *)(el)?if '
  local multiline_then_end_regex='^(.*)\; (then( *#.*)?)$'
  local within_test_regex='^( *)(((! )?-[fdrwxes])|([^\[]+ == ))'
  local base_indent=''
  local extra_indent=''
  local line
  local lastline=''

  if [[ "$1" =~ ${multiline_if_begin_regex} ]]
  then
    base_indent="${BASH_REMATCH[1]}"
    [[ -n "${BASH_REMATCH[2]}" ]] && extra_indent='  '
    echo "$1"
    shift
  fi

  while [[ "$#" -gt 0 ]]
  do
    line="$1"
    shift
    if [[ "${line}" =~ ${multiline_then_end_regex} ]]
    then
      line="${BASH_REMATCH[1]}"
      lastline="${base_indent}${BASH_REMATCH[2]}"
    fi
    if [[ "${line}" =~ ${within_test_regex} ]]
    then
      echo "  ${extra_indent}${line}"
    else
      echo " ${extra_indent}${line}"
    fi
  done

  echo "${lastline}"
}

# Wrap `then` and `do` to a separated line
# before:                   after:
#   if [[ ... ]]; then        if [[ ... ]]
#                             then
#
# before:                   after:
#   if [[ ... ]] ||           if [[ ... ]] ||
#     [[ ... ]]; then           [[ ... ]]
#                             then
#
# before:                   after:
#   for var in ...; do        for var in ...
#                             do
#
wrap_then_do() {
  local file="$1"
  local tempfile="$2"

  local -a processed
  local line
  local singleline_then_regex='^( *)(el)?if (.+)\; (then( *#.*)?)$'
  local singleline_do_regex='^( *)(for|while) (.+)\; (do( *#.*)?)$'
  local multiline_if_begin_regex='^( *)(el)?if '
  local multiline_then_end_regex='^(.*)\; (then( *#.*)?)$'
  local -a buffer=()

  while IFS='' read -r line
  do
    if [[ "${#buffer[@]}" == 0 ]]
    then
      if [[ "${line}" =~ ${singleline_then_regex} ]]
      then
        processed+=("${BASH_REMATCH[1]}${BASH_REMATCH[2]}if ${BASH_REMATCH[3]}")
        processed+=("${BASH_REMATCH[1]}${BASH_REMATCH[4]}")
      elif [[ "${line}" =~ ${singleline_do_regex} ]]
      then
        processed+=("${BASH_REMATCH[1]}${BASH_REMATCH[2]} ${BASH_REMATCH[3]}")
        processed+=("${BASH_REMATCH[1]}${BASH_REMATCH[4]}")
      elif [[ "${line}" =~ ${multiline_if_begin_regex} ]]
      then
        buffer=("${line}")
      else
        processed+=("${line}")
      fi
    else
      buffer+=("${line}")
      if [[ "${line}" =~ ${multiline_then_end_regex} ]]
      then
        while IFS='' read -r line
        do
          processed+=("${line}")
        done < <(align_multiline_if_condition "${buffer[@]}")
        buffer=()
      fi
    fi
  done <"${tempfile}"

  printf "%s\n" "${processed[@]}" >"${tempfile}"
}

# TODO: it's hard to align multiline switch cases
align_multiline_switch_cases() {
  true
}

format() {
  local file="$1"
  if [[ ! -f "${file}" || ! -r "${file}" ]]
  then
    onoe "File \"${file}\" is not readable."
    return 1
  fi

  # shellcheck disable=SC2155
  local tempfile="$(dirname "${file}")/.${file##*/}.temp"

  trap 'rm -f "${tempfile}" 2>/dev/null' RETURN
  cp -af "${file}" "${tempfile}"

  if [[ ! -f "${tempfile}" || ! -w "${tempfile}" ]]
  then
    onoe "File \"${tempfile}\" is not writable."
    return 1
  fi

  # Format with `shfmt` first
  if ! "${SHFMT}" -w "${SHFMT_ARGS[@]}" "${tempfile}"
  then
    onoe "Failed to run \`shfmt\`"
    return 1
  fi

  # Fail fast when forbidden patterns detected
  if ! no_forbiddens "${file}" "${tempfile}"
  then
    return 2
  fi

  # Tweak it with custom shell script styles
  wrap_then_do "${file}" "${tempfile}"
  align_multiline_switch_cases "${file}" "${tempfile}"

  if ! diff -q "${file}" "${tempfile}" &>/dev/null
  then
    # Show differences
    diff -d -C 1 --color=auto "${file}" "${tempfile}"
    if [[ -n "${INPLACE}" ]]
    then
      cp -af "${tempfile}" "${file}"
    fi
    return 2
  else
    # File is identical between code formations (good styling)
    return 0
  fi
}

RETCODE=0
for file in "${FILES[@]}"
do
  if ! format "${file}"
  then
    if [[ "$?" == 1 ]]
    then
      onoe "${0##*/}: Failed to format file \"${file}\". Function exited with code 1."
    else
      onoe "${0##*/}: Bad style for file \"${file}\". Function exited with code 2."
    fi
    onoe
    RETCODE=1
  fi
done

exit "${RETCODE}"