# Query the selected instance; only options before the verb belong to the client.
_kiln_client() {
  local cur="${COMP_WORDS[COMP_CWORD]}" i=1 line
  local -a options=() words=()
  COMPREPLY=()
  while (( i < COMP_CWORD )); do
    case "${COMP_WORDS[i]}" in
      --json) ((i+=1)) ;;
      -s|--socket)
        (( i+1 == COMP_CWORD )) && return
        options+=(--socket "${COMP_WORDS[i+1]}")
        ((i+=2)) ;;
      -h|--help) return ;;
      *) break ;;
    esac
  done
  if (( i == COMP_CWORD )) && [[ "$cur" == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W '--json --socket --help -s -h' -- "$cur")
    return
  fi
  while (( i <= COMP_CWORD )); do words+=("${COMP_WORDS[i]}"); ((i+=1)); done
  while IFS= read -r line; do
    if [[ -n "$line" && "$line" == "$cur"* ]]; then
      COMPREPLY+=("$(printf '%q' "$line")")
    fi
  done < <("${COMP_WORDS[0]}" "${options[@]}" complete "${#words[@]}" "${words[@]}" 2>/dev/null)
}
complete -F _kiln_client kiln-client
