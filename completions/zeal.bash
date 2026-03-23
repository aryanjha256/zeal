# Bash completion for zeal
# Install: cp zeal.bash /etc/bash_completion.d/zeal

_zeal() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Top-level options
    opts="-h --help -V --version -f --file --format --no-color --color -F --follow --explain"

    case "$prev" in
        -f|--file)
            # Complete file paths
            COMPREPLY=( $(compgen -f -- "$cur") )
            return 0
            ;;
        --format)
            COMPREPLY=( $(compgen -W "text json raw" -- "$cur") )
            return 0
            ;;
        --color)
            COMPREPLY=( $(compgen -W "auto always never" -- "$cur") )
            return 0
            ;;
    esac

    # If current word starts with -, complete options
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
        return 0
    fi

    # Default: file completion (for query strings, user types quotes manually)
    COMPREPLY=( $(compgen -f -- "$cur") )
    return 0
}

complete -F _zeal zeal
