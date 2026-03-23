# Fish completion for zeal
# Install: cp zeal.fish ~/.config/fish/completions/zeal.fish

complete -c zeal -s h -l help -d 'Show help'
complete -c zeal -s V -l version -d 'Show version'
complete -c zeal -s f -l file -r -F -d 'Log file (alternative to FROM clause)'
complete -c zeal -l format -r -xa 'text json raw' -d 'Output format'
complete -c zeal -l no-color -d 'Disable ANSI color output'
complete -c zeal -l color -r -xa 'auto always never' -d 'Color mode'
complete -c zeal -s F -l follow -d 'Follow file for new entries'
complete -c zeal -l explain -d 'Show query plan without executing'
