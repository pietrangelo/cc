# cc

**cc** keeps a repository's Claude Code configuration (CLAUDE.md, rules, skills,
agents, commands, hook scripts) encrypted on GitHub, and decrypts it
automatically when a Claude Code session starts, locally or in the cloud.

Encryption is done by [sec](https://github.com/pietrangelo/sec) (v2:
XChaCha20-Poly1305, STREAM chunks, deterministic mode for git filters) through a
git clean/smudge filter. Anyone who clones the repository without the key sees
only ciphertext. Whoever runs a session with the key, Claude included, sees the
plaintext. Nothing can make a file readable by Claude but not by the person who
controls the session.

## How it works

| File | In git | Why |
| :- | :- | :- |
| `.claude/**` (skills, agents, commands, hooks, rules) | encrypted | the protected configuration |
| `.claude/private/CLAUDE.md` | encrypted | the real project instructions |
| `CLAUDE.md` (root) | clear | a stub: Claude Code reads it at launch, before any hook can decrypt it |
| `.claude/settings.json` | clear | holds the SessionStart hook, so it must be readable to run |
| `.claude/cc/` | clear | this script and its config (key id, pinned sec version) |

When a session starts, the SessionStart hook (`.claude/cc/cc session-start`):

1. takes the key from `SEC_TOOL_KEY` or from `~/.config/cc/keys/<key id>.key`;
2. installs the pinned sec release if needed (checked against its `SHA256SUMS`,
   or built from the tag with Go);
3. configures the git filter and checks out the protected files again, so the
   working tree holds plaintext;
4. hands Claude the content of `.claude/private/*.md` as project instructions
   (or, past the 10,000 character hook limit, tells Claude to read them first);
5. asks Claude Code to reload skills and commands, since skill discovery runs
   before the hook (agents are reloaded by Claude Code's own file watcher);
6. adds `unset SEC_TOOL_KEY` to the session environment, so the commands Claude
   runs do not carry the key (the git filter reads it from the key file).

Without a key, or with the wrong one, the hook changes nothing and tells Claude
that the configuration is locked.

## Setup

Requirements: git, bash, curl, and jq for `init`.

```bash
git clone https://github.com/pietrangelo/cc
cc/cc init /path/to/your/repo
```

`init` generates a key in `~/.config/cc/keys/`, adds the rules to
`.gitattributes`, moves `CLAUDE.md` and `.claude/rules/` into `.claude/private/`
and writes the stub, adds the hook to `.claude/settings.json`, installs a
pre-commit hook and a GitHub Actions check, and stages everything encrypted.
Review the result, then:

```bash
git commit -m "Encrypt Claude configuration"
.claude/cc/cc scan-history   # were these files ever committed in clear?
```

Back up the key file: it is the only way to decrypt the files.

### Cloud sessions

Add the key to the cloud environment as an environment variable named
`SEC_TOOL_KEY`, with the content of the key file. The setup script cannot read
environment variables, so decryption happens in the SessionStart hook.

### Another machine

Copy the key file to `~/.config/cc/keys/` (or export `SEC_TOOL_KEY`) and run
`.claude/cc/cc unlock`, or just start Claude Code: the hook unlocks the clone.

## Commands

| Command | What it does |
| :- | :- |
| `cc init [repo]` | protect a repository |
| `cc unlock [repo]` | configure the filter and decrypt the working tree |
| `cc lock [repo]` | remove the filter and put ciphertext back on disk |
| `cc status [repo]` | list protected files, encrypted or not, locked or clear |
| `cc check [repo]` | fail if a staged file that must be encrypted is not (pre-commit, CI) |
| `cc scan-history [repo]` | list every past blob of a protected path stored in clear |
| `cc session-start` | the SessionStart hook |

`check` and `scan-history` treat as protected everything under `.claude/` except
`settings.json` and `cc/`, every `CLAUDE.md` and `CLAUDE.local.md` other than the
root stub, and any path with `filter=sec` in `.gitattributes`.

## Limits

- **Leaked history.** Encrypting now does not hide what was pushed before. If
  `scan-history` finds plaintext blobs that were public, rewrite the history
  (for example with `git filter-repo`) and consider the content published.
- **Equality.** Deterministic encryption reveals whether two protected files
  are identical, and when a file changes. That is what lets `git status` work.
- **Merges.** Git merges the encrypted blobs, so concurrent edits to the same
  protected file conflict as binary files: resolve them by hand.
- **Readers of the session.** The key is in the session's environment and key
  file, and the plaintext is on its disk. This protects the files from people
  who only see the repository, not from people who run sessions with the key.

## Tests

```bash
SEC_BIN=/path/to/sec tests/e2e.sh
```

## License

GNU Affero General Public License v3 or later.
