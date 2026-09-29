# Agent hint

`rules/fas/du.cue` tells agents that run `du` what it misses on APFS and which moira
flags answer it. Each case evaluates a PreToolUse payload against the rule alone.

## Setup

```scrut
$ source "$TESTDIR"/_setup.sh
```

## Fires on du

```scrut
$ fas_hint 'du -sh ~/projects'
HINT: On APFS `du` charges every clone and hard link in full and cannot see space a snapshot holds. `moira` takes du's flags: `moira --du -s PATH` reports each entry's fair share, `--exclusive` what deleting frees, `--pinned` what a snapshot still holds, and `moira --columns` shows all of them.
```

```scrut
$ fas_hint 'cd /tmp && du -a build | sort -n' | cut -c1-5
HINT:
```

## Stays quiet otherwise

```scrut
$ fas_hint 'moira --du -s .'
no hint
```

```scrut
$ fas_hint 'echo du'
no hint
```
