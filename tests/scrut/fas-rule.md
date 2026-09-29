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
HINT: On APFS `du` charges every clone and hard link in full and cannot see space a snapshot holds. `moira` prints what du prints and takes its flags; add `-S` for each entry's fair share, `-E` for what deleting frees, `-p` for what a snapshot still holds, or `-C` for all of them.
```

```scrut
$ fas_hint 'cd /tmp && du -a build | sort -n' | cut -c1-5
HINT:
```

## Stays quiet otherwise

```scrut
$ fas_hint 'moira -Ss .'
no hint
```

```scrut
$ fas_hint 'echo du'
no hint
```
