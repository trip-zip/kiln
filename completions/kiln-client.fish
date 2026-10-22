function __kiln_client_complete
    set -l typed (commandline -opc)
    set -l options
    set -l words
    set -l leading 1
    set -l socket_pending 0
    for w in $typed[2..-1]
        if test $socket_pending -eq 1
            set -a options --socket "$w"
            set socket_pending 0
        else if test $leading -eq 1
            switch "$w"
                case --json
                case -s --socket
                    set socket_pending 1
                case -h --help
                    return
                case '*'
                    set leading 0
                    set -a words "$w"
            end
        else
            set -a words "$w"
        end
    end
    if test $socket_pending -eq 1
        return
    end
    set -l current (commandline -ct)
    if not set -q current[1]
        set current ''
    end
    set -a words "$current"
    command "$typed[1]" $options complete (count $words) $words 2>/dev/null
end
complete -c kiln-client -f -a '(__kiln_client_complete)'
