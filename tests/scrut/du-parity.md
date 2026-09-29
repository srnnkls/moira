# du(1) parity

With `--du --allocated`, moira must print what the macOS `du` prints for the same flags.
Each case runs both over a fixture tree built in scrut's per-document tempdir and expects
an empty diff.

## Setup

```scrut
$ source "$TESTDIR"/_setup.sh && make_tree
```

## Hierarchy and depth

```scrut
$ du_parity tree
```

```scrut
$ du_parity -a tree
```

```scrut
$ du_parity -s tree tree/sub
```

```scrut
$ du_parity -d 1 tree
```

```scrut
$ du_parity -d2 tree
```

## Units

```scrut
$ du_parity -k tree
```

```scrut
$ du_parity -m -d 1 tree
```

```scrut
$ du_parity -g -s tree
```

```scrut
$ du_parity -ah tree
```

```scrut
$ du_parity -s --si tree
```

```scrut
$ BLOCKSIZE=1K du_parity -s tree
```

```scrut
$ du_parity -s -B 4096 tree
```

```scrut
$ du_parity -a -B 1000 tree
```

```scrut
$ du_parity -a -A -B 1000 tree
```

## Counting

A hard-linked file is counted and shown once unless `-l` asks for every link.

```scrut
$ du_parity -sl tree
```

```scrut
$ du_parity -c tree/small tree/sub
```

```scrut
$ du_parity -sA tree
```

```scrut
$ du_parity -aA tree
```

## Selection

```scrut
$ du_parity -a -I '*.o' tree
```

```scrut
$ du_parity -a -t 1M tree
```

```scrut
$ du_parity -sx tree
```

## Symlinks

```scrut
$ du_parity tree/link
```

```scrut
$ du_parity -H tree/link
```

```scrut
$ du_parity -aL tree
```

## Errors

```scrut
$ du_parity -s tree/missing
```
