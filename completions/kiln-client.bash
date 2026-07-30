# Candidates come from the running compositor, so this file never goes stale
# against the build it completes for.
_kiln_client() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  if [[ "$cur" == -* ]]; then
    COMPREPLY=($(compgen -W "--json --socket --help" -- "$cur"))
    return
  fi
  # The client's own flags are not verb words. Left in, every candidate would
  # answer for the wrong argument position, which reads as completion offering
  # the wrong thing rather than as anything failing.
  local -a words=()
  local i
  for ((i = 1; i <= COMP_CWORD; i++)); do
    case "${COMP_WORDS[i]}" in
      --json) ;;
      -s|--socket) i=$((i + 1)) ;;
      *) words+=("${COMP_WORDS[i]}") ;;
    esac
  done
  # Read one candidate per line and filter here, rather than handing the whole
  # answer to `compgen -W`, which word-splits it: a tag or an app_id holding a
  # space would arrive as two candidates, each of them a name that resolves to
  # nothing. Quoted on the way out for the same reason, so what lands on the
  # command line is one argument.
  local line prefix="${cur//\\/}"
  COMPREPLY=()
  while IFS= read -r line; do
    if [[ "$line" == "$prefix"* ]]; then
      COMPREPLY+=("$(printf '%q' "$line")")
    fi
  done < <(kiln-client complete "${#words[@]}" "${words[@]}" 2>/dev/null)
}
complete -F _kiln_client kiln-client
