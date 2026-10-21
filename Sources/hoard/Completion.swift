import Foundation

enum Completion {
    private static func flags(for command: String) -> [String] {
        let common = ["--json", "--strict"]
        switch command {
        case "scan": return common + ["--top", "--threads", "--sequential", "--save"]
        case "top": return common + ["--files", "--dirs", "--limit", "--depth"]
        case "stale": return common + ["--days", "--min-size", "--limit", "--no-spotlight"]
        case "types", "suggest", "dupes", "similar", "apps":
            switch command {
            case "suggest": return common + ["--min-size", "--limit"]
            case "dupes", "similar": return common + ["--min-size", "--limit", "--timeout"] + (command == "similar" ? ["--threshold"] : [])
            default: return common + ["--limit"]
            }
        case "diff": return common + ["--from", "--to"]
        case "protect": return common + ["--lock", "--guard", "--note"]
        case "guardian": return common + ["--once"]
        case "uninstall-plan": return ["--json"]
        case "cleanup-log": return ["--limit", "--json"]
        case "doctor": return ["--json"]
        case "completion", "mcp": return []
        default: return common
        }
    }

    static func script(shell: String, commands: [String]) -> String? {
        switch shell {
        case "zsh":
            let cases = commands.map { "    \($0)) compadd -- \(flags(for: $0).joined(separator: " ")) ;;" }.joined(separator: "\n")
            return """
            #compdef hoard
            _hoard() {
              if (( CURRENT == 2 )); then
                compadd -- \(commands.joined(separator: " "))
                return
              fi
              if [[ ${words[CURRENT]} == -* ]]; then
                case ${words[2]} in
            \(cases)
                esac
              elif [[ ${words[2]} == completion ]]; then
                compadd -- zsh bash fish
              else
                _files
              fi
            }
            compdef _hoard hoard
            """
        case "bash":
            let cases = commands.map { "    \($0)) options='\(flags(for: $0).joined(separator: " "))' ;;" }.joined(separator: "\n")
            return """
            _hoard_completion() {
              local cur="${COMP_WORDS[COMP_CWORD]}" options=''
              if (( COMP_CWORD == 1 )); then
                COMPREPLY=( $(compgen -W '\(commands.joined(separator: " "))' -- "$cur") )
                return
              fi
              if [[ "$cur" == -* ]]; then
                case "${COMP_WORDS[1]}" in
            \(cases)
                esac
                COMPREPLY=( $(compgen -W "$options" -- "$cur") )
              elif [[ "${COMP_WORDS[1]}" == completion ]]; then
                COMPREPLY=( $(compgen -W 'zsh bash fish' -- "$cur") )
              fi
            }
            # -o default: an empty reply falls back to the shell's own file name completion.
            complete -o default -F _hoard_completion hoard
            """
        case "fish":
            let names = commands.joined(separator: " ")
            let rows = commands.flatMap { command in
                flags(for: command).map { flag in
                    let takesValue = ["--top", "--threads", "--limit", "--depth", "--days", "--min-size", "--timeout", "--threshold", "--from", "--to", "--note"].contains(flag)
                    return "complete -c hoard -n '__fish_seen_subcommand_from \(command)' -l \(flag.dropFirst(2))\(takesValue ? " -r" : "")"
                }
            }.joined(separator: "\n")
            return """
            complete -c hoard -n 'not __fish_seen_subcommand_from \(names)' -f -a '\(names)'
            complete -c hoard -n '__fish_seen_subcommand_from completion' -f -a 'zsh bash fish'
            \(rows)
            """
        default: return nil
        }
    }
}
