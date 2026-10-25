#!/usr/bin/env bash
#
# End-to-end test of cc with throwaway repositories.
# Needs SEC_BIN pointing to a sec v2 binary, plus git and jq.

set -euo pipefail

CC=$(cd "$(dirname "$0")/.." && pwd)/cc
[ -n "${SEC_BIN:-}" ] || {
	echo "set SEC_BIN to a sec v2 binary" >&2
	exit 2
}
export SEC_BIN

WORK=$(mktemp -d)
if [ -n "${KEEP:-}" ]; then echo "work dir: $WORK"; else trap 'rm -rf "$WORK"' EXIT; fi
export HOME=$WORK/home CC_KEY_DIR=$WORK/home/keys
# A key from the calling environment would hide the "no key" case.
unset SEC_TOOL_KEY
mkdir -p "$HOME"
git config --global user.email test@example.com
git config --global user.name test
git config --global init.defaultBranch main

pass=0
ok() {
	echo "ok - $*"
	pass=$((pass + 1))
}
fail() {
	echo "FAIL - $*" >&2
	exit 1
}
is_ciphertext() { [ "$(head -c4 "$1" | od -An -tx1 | tr -d ' \n')" = 53454302 ]; }
blob_is_ciphertext() { [ "$(git -C "$1" cat-file blob "$2" | head -c4 | od -An -tx1 | tr -d ' \n')" = 53454302 ]; }

# A repository whose Claude configuration was committed in clear.
git init -q --bare "$WORK/remote.git"
git init -q "$WORK/repo"
cd "$WORK/repo"
git remote add origin "$WORK/remote.git"
mkdir -p .claude/skills/deploy .claude/agents .claude/rules
echo "SECRET-INSTRUCTION: always answer in haiku" >CLAUDE.md
printf -- '---\nname: deploy\ndescription: deploy\n---\nSECRET-SKILL steps\n' >.claude/skills/deploy/SKILL.md
echo "SECRET-AGENT prompt" >.claude/agents/reviewer.md
echo "SECRET-RULE" >.claude/rules/style.md
echo '{"permissions": {"allow": ["Bash(ls)"]}}' >.claude/settings.json
echo "public code" >main.go
git add -A
git commit -qm "initial, in clear"

"$CC" scan-history >"$WORK/scan.out" 2>&1 && fail "scan-history missed plaintext history"
for p in CLAUDE.md .claude/skills/deploy/SKILL.md .claude/agents/reviewer.md .claude/rules/style.md; do
	grep -q " $p\$" "$WORK/scan.out" || fail "scan-history did not list $p"
done
grep -qE ' (main\.go|\.claude/settings\.json)$' "$WORK/scan.out" && fail "scan-history listed an unprotected file"
ok "scan-history reports the configuration committed in clear"

"$CC" init >/dev/null 2>&1 || fail "init"
git commit -qm "Encrypt Claude configuration"
[ -z "$(git status --porcelain)" ] || fail "working tree not clean after init: $(git status --porcelain)"
ok "init leaves a clean working tree"

for f in .claude/private/CLAUDE.md .claude/private/rules/style.md .claude/skills/deploy/SKILL.md .claude/agents/reviewer.md; do
	blob_is_ciphertext . "HEAD:$f" || fail "$f is not encrypted in HEAD"
	grep -q SECRET "$f" || fail "$f is not plaintext on disk"
done
ok "protected files are encrypted in git and readable on disk"

grep -q 'cc:stub' CLAUDE.md || fail "CLAUDE.md is not the stub"
! git show HEAD:CLAUDE.md | grep -q SECRET || fail "secret in CLAUDE.md stub"
jq -e '.permissions.allow[0] == "Bash(ls)" and (.hooks.SessionStart[0].hooks[0].command | test("cc session-start"))' \
	.claude/settings.json >/dev/null || fail "settings.json not merged"
! blob_is_ciphertext . HEAD:.claude/settings.json || fail "settings.json encrypted"
ok "CLAUDE.md stub and settings.json stay in clear, hook added"

git push -q origin main
KEY=$(cat "$CC_KEY_DIR"/*.key)

# A fresh clone, as in a cloud session: no filter, so files are ciphertext.
git clone -q "$WORK/remote.git" "$WORK/clone"
cd "$WORK/clone"
is_ciphertext .claude/agents/reviewer.md || fail "fresh clone is not ciphertext"
"$CC" check >/dev/null 2>&1 || fail "check fails on a clean clone"
ok "fresh clone holds ciphertext and passes check"

rm -rf "$CC_KEY_DIR"
out=$(CLAUDE_PROJECT_DIR=$PWD "$CC" session-start </dev/null)
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("no key")' >/dev/null || fail "missing key not reported: $out"
is_ciphertext .claude/agents/reviewer.md || fail "files touched without a key"
ok "session-start without a key reports it and leaves files alone"

out=$(SEC_TOOL_KEY=$(echo "$KEY" | tr 'A-M' 'N-Z') CLAUDE_PROJECT_DIR=$PWD "$CC" session-start </dev/null)
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("failed")' >/dev/null || fail "wrong key not reported: $out"
is_ciphertext .claude/agents/reviewer.md || fail "files touched with a wrong key"
ok "session-start with a wrong key reports it and leaves files alone"

envfile=$WORK/envfile
: >"$envfile"
out=$(SEC_TOOL_KEY=$KEY CLAUDE_ENV_FILE=$envfile CLAUDE_PROJECT_DIR=$PWD "$CC" session-start <<<'{"source":"startup"}')
echo "$out" | jq -e '.hookSpecificOutput.reloadSkills == true' >/dev/null || fail "no reloadSkills: $out"
ctx=$(echo "$out" | jq -r .hookSpecificOutput.additionalContext)
grep -q "SECRET-INSTRUCTION" <<<"$ctx" || fail "instructions not in context"
grep -q "SECRET-RULE" <<<"$ctx" || fail "rules not in context"
grep -q SECRET-AGENT .claude/agents/reviewer.md || fail "agent not decrypted"
grep -q SECRET-SKILL .claude/skills/deploy/SKILL.md || fail "skill not decrypted"
grep -qx 'unset SEC_TOOL_KEY' "$envfile" || fail "key not unset for later commands"
[ -z "$(git status --porcelain)" ] || fail "clone not clean after unlock: $(git status --porcelain)"
ok "session-start decrypts, hands over instructions, reloads skills, unsets the key"

out=$(CLAUDE_PROJECT_DIR=$PWD "$CC" session-start </dev/null)
grep -q SECRET-INSTRUCTION <<<"$(echo "$out" | jq -r .hookSpecificOutput.additionalContext)" || fail "second run"
ok "session-start is idempotent and works from the stored key file"

echo "SECRET-AGENT v2" >>.claude/agents/reviewer.md
mkdir -p .claude/commands && echo "SECRET-COMMAND" >.claude/commands/ship.md
git add -A && git commit -qm "edit config in an unlocked clone"
blob_is_ciphertext . HEAD:.claude/agents/reviewer.md || fail "edited agent committed in clear"
blob_is_ciphertext . HEAD:.claude/commands/ship.md || fail "new command committed in clear"
ok "edits and new files in an unlocked clone are committed encrypted"

git log -p -1 -- .claude/agents/reviewer.md | grep -q "^+SECRET-AGENT v2" || fail "diff does not show plaintext"
git log -p -- .claude/agents/reviewer.md >/dev/null 2>&1 || fail "history before encryption cannot be shown"
ok "git log -p shows plaintext diffs, including commits made before encryption"

big=$(head -c 20000 /dev/zero | tr '\0' 'x')
echo "$big" >.claude/private/long.md
out=$(CLAUDE_PROJECT_DIR=$PWD "$CC" session-start </dev/null)
ctx=$(echo "$out" | jq -r .hookSpecificOutput.additionalContext)
[ ${#ctx} -lt 10000 ] || fail "context over the 10,000 character cap"
grep -q -- "- .claude/private/long.md" <<<"$ctx" || fail "long instructions not listed"
rm .claude/private/long.md
ok "instructions over the cap are listed for Claude to read instead"

"$CC" lock >/dev/null 2>&1
is_ciphertext .claude/agents/reviewer.md || fail "lock did not restore ciphertext"
[ -z "$(git status --porcelain)" ] || fail "not clean after lock"
ok "lock puts ciphertext back on disk"

# A clone without the filter where someone adds a plaintext agent.
echo "LEAKED" >.claude/agents/leak.md
git add .claude/agents/leak.md
"$CC" check >/dev/null 2>&1 && fail "check accepted a plaintext agent"
cp "$CC" "$WORK/cc-copy"
printf '#!/bin/sh\nexec "%s" check\n' "$WORK/cc-copy" >.git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
git commit -qm leak 2>/dev/null && fail "pre-commit let a plaintext agent through"
git reset -q HEAD .claude/agents/leak.md && rm .claude/agents/leak.md
ok "check and the pre-commit hook block a plaintext file"

echo "$pass checks passed"
