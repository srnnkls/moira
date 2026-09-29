# Metrics beyond du(1)

Shares, exclusive space and pinned space over clones with known physical usage: a full
pair shares 1 MiB, and a partial pair shares 768 KiB after 256 KiB of one side is
rewritten. Fixtures are new, so no snapshot holds them and pinned stays 0.

## Setup

```scrut
$ source "$TESTDIR"/_setup.sh && make_tree && make_clones
```

## Clone pairs

A full pair splits its 1 MiB; a partial pair charges each side its 256 KiB of private
blocks plus half of the 768 KiB still shared. Shares sum to the space the pairs occupy.

```scrut
$ moira -C -k clones/full clones/partial
 allocated      share  exclusive     pinned  path
      2048       1024          0          0  clones/full
      2048       1280        512          0  clones/partial
```

```scrut
$ moira -C -k -a clones/partial
 allocated      share  exclusive     pinned  path
      1024        640        256          0  clones/partial/a
      1024        640        256          0  clones/partial/b
      2048       1280        512          0  clones/partial
```

```scrut
$ moira -E -k -s clones
512	clones
```

## Hard links

Each link carries half of the inode, so the tree's share equals what du(1) counts once.

```scrut
$ moira -S -k -s tree && moira -k -s tree
4572	tree
4572	tree
```

## Negative thresholds

macOS du(1) prints nothing for any negative threshold. moira follows the manual instead
and shows directories smaller than the threshold.

```scrut
$ moira -k -t -102400 tree
0	tree/empty
20	tree/deep/a/b/c
20	tree/deep/a/b
20	tree/deep/a
20	tree/deep
```

## Output

Output appends to a shared file descriptor instead of overwriting it.

```scrut
$ { moira -k -s tree/sub; moira -k -s tree/deep; } >both.out && cat both.out
1468	tree/sub
20	tree/deep
```

```scrut
$ moira -a -s tree 2>&1 | head -1
moira: -a cannot be combined with -s or -d: tree
```

```scrut
$ moira --version
moira *.*.* (glob)
```

## Sharing hint

On a terminal, a run that met shared blocks names the flags that account for them. Output
to pipes and files stays exactly what du(1) prints.

```scrut
$ on_terminal moira -sk clones | tail -1
moira: 1.8M of 4.0M is shared through clones or hard links; -S shows each entry's share, -C every metric
```

```scrut
$ on_terminal moira -sk tree/sub | wc -l | tr -d ' '
1
```

```scrut
$ moira -sk clones 2>&1 >/dev/null | wc -l | tr -d ' '
0
```
