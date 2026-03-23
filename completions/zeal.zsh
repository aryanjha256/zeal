#compdef zeal
# Zsh completion for zeal
# Install: cp zeal.zsh /usr/local/share/zsh/site-functions/_zeal

_zeal() {
    local -a opts
    opts=(
        '(-h --help)'{-h,--help}'[Show help]'
        '(-V --version)'{-V,--version}'[Show version]'
        '(-f --file)'{-f,--file}'[Log file (alternative to FROM clause)]:file:_files'
        '--format[Output format]:format:(text json raw)'
        '--no-color[Disable ANSI color output]'
        '--color[Color mode]:mode:(auto always never)'
        '(-F --follow)'{-F,--follow}'[Follow file for new entries]'
        '--explain[Show query plan without executing]'
        '*:query:'
    )

    _arguments -s $opts
}

_zeal "$@"
