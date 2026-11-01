# lazygit integration

[lazygit](https://github.com/jesseduffield/lazygit) custom commands can drive
`git issue`, so issues are one keypress away while you work on code. lazygit
only runs `git issue …` commands and reads `git issue ls --format oneline`
for its pickers, so nothing here depends on git-native-issuez internals.

## Configuration

Add this to lazygit's `config.yml` (`lazygit --print-config-dir` shows where
it lives). One key, `I` (shift+i, unused by lazygit's defaults), opens a menu
of issue actions, so no built-in keybinding is shadowed:

```yaml
customCommands:
  - key: 'I'
    description: 'Issues'
    commandMenu:
      - key: 'l'
        description: 'List open issues'
        command: 'git issue ls --format full'
        output: 'popup'
        outputTitle: 'Open issues'
      - key: 'a'
        description: 'List all issues'
        command: 'git issue ls --all --format full'
        output: 'popup'
        outputTitle: 'All issues'
      - key: 's'
        description: 'Show issue'
        prompts:
          - type: 'menuFromCommand'
            title: 'Issue'
            key: 'Issue'
            command: 'git issue ls --all --format oneline'
            filter: '(?P<value>^\S+)\s+(?P<state>\S+)\s+(?P<title>.+)$'
            valueFormat: '{{ .value }}'
            labelFormat: '{{ .value }} {{ .state }} {{ .title }}'
        command: 'git issue show {{.Form.Issue | quote}}'
        output: 'popup'
        outputTitle: 'Issue'
      - key: 'n'
        description: 'New issue'
        prompts:
          - type: 'input'
            title: 'Title'
            key: 'Title'
          - type: 'menu'
            title: 'Priority'
            key: 'Priority'
            options:
              - name: 'none'
                value: ''
              - name: 'low'
                value: 'low'
              - name: 'medium'
                value: 'medium'
              - name: 'high'
                value: 'high'
              - name: 'critical'
                value: 'critical'
          - type: 'input'
            title: 'Label (optional; add more with git issue edit)'
            key: 'Label'
        command: >-
          git issue create {{.Form.Title | quote}}
          {{if .Form.Priority}}-p {{.Form.Priority}}{{end}}
          {{if .Form.Label}}-l {{.Form.Label | quote}}{{end}}
        output: 'log'
      - key: 'c'
        description: 'Comment on issue'
        prompts:
          - type: 'menuFromCommand'
            title: 'Issue'
            key: 'Issue'
            command: 'git issue ls --format oneline'
            filter: '(?P<value>^\S+)\s+(?P<state>\S+)\s+(?P<title>.+)$'
            valueFormat: '{{ .value }}'
            labelFormat: '{{ .value }} {{ .title }}'
          - type: 'input'
            title: 'Comment'
            key: 'Comment'
        command: 'git issue comment {{.Form.Issue | quote}} -m {{.Form.Comment | quote}}'
        output: 'log'
      - key: 'x'
        description: 'Close issue'
        prompts:
          - type: 'menuFromCommand'
            title: 'Issue'
            key: 'Issue'
            command: 'git issue ls --format oneline --state open'
            filter: '(?P<value>^\S+)\s+(?P<state>\S+)\s+(?P<title>.+)$'
            valueFormat: '{{ .value }}'
            labelFormat: '{{ .value }} {{ .title }}'
          - type: 'menu'
            title: 'Reason'
            key: 'Reason'
            options:
              - name: 'completed'
                value: 'completed'
              - name: 'duplicate'
                value: 'duplicate'
              - name: 'wontfix'
                value: 'wontfix'
              - name: 'invalid'
                value: 'invalid'
        command: 'git issue state {{.Form.Issue | quote}} --close --reason {{.Form.Reason}}'
        output: 'log'
      - key: 'f'
        description: 'Search issues'
        prompts:
          - type: 'input'
            title: 'Search for'
            key: 'Pattern'
        command: 'git issue search {{.Form.Pattern | quote}}'
        output: 'popup'
        outputTitle: 'Search results'
      - key: 'y'
        description: 'Sync issues with origin'
        command: 'git issue sync origin'
        output: 'log'
```

| Key | Action |
| --- | --- |
| `I` `l` / `a` | List open / all issues |
| `I` `s` | Show an issue (picker) |
| `I` `n` | New issue: title, priority, one optional label |
| `I` `c` | Comment on an open issue (picker) |
| `I` `x` | Close an open issue with a reason (picker) |
| `I` `f` | Search issues |
| `I` `y` | Sync issues with `origin` (merge, then push) |

Notes:

- The menu needs lazygit's `commandMenu`; the configuration was checked
  against lazygit 0.64, which validates it on start.
- Values go through lazygit's `quote`, so titles and comments may contain
  spaces and quotes.
- Change `origin` in the sync entry to your remote. Without `git issue init`
  it works all the same: `sync` fetches issues itself.

## Upstream's configuration

The custom commands in upstream git-native-issue's
`docs/lazygit.md` also work unchanged with git-native-issuez: they use the
same commands and the same `--format oneline` output (`<id> <state> <title>`).
`test/cli_git.zig` runs each of them, as lazygit expands them, against our
binary. They bind `c`, `C`, `i`, `I`, `X` and `/` globally, which
shadows lazygit's own commit, ignore and search keys; the menu above avoids
that.
