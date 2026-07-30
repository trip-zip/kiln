# Candidates come from the running compositor, so this file never goes stale
# against the build it completes for.
function __kiln_client_complete
    set -l typed (commandline -opc)
    # The client's own flags are not verb words, and leaving them in would
    # shift every candidate to the wrong argument position.
    set -l words
    set -l skip 0
    for w in $typed[2..-1]
        if test $skip -eq 1
            set skip 0
        else
            switch $w
                case --json
                case -s --socket
                    set skip 1
                case '*'
                    set -a words $w
            end
        end
    end
    set -a words (commandline -ct)
    kiln-client complete (count $words) $words 2>/dev/null
end
complete -c kiln-client -f -a "(__kiln_client_complete)"
complete -c kiln-client -l json -d 'reply as JSON'
complete -c kiln-client -l socket -r -d 'socket path'
