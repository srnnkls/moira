# moira

*μοῖρα • a portion, one's allotted share*

> From μείρομαι (meíromai, "to receive as one's portion"), from Proto-Indo-European \*(s)mer- ("to allot")
>
> Pronunciation: /ˈmoi̯.ra/

## About

moira is `du` for APFS. On APFS, `cp` clones files, build caches clone their artifacts, and
Time Machine keeps hourly local snapshots, so the number `du` prints is not what deleting a
directory frees. `du` charges every clone in full and says nothing about snapshots.

moira charges each file its share of the blocks it holds. Clones split what they still have
in common, a rewritten clone owns its rewritten blocks, and hard links split their inode.
Summed over a volume, the shares equal the space the volume uses. Alongside the share, moira
reports what deletion frees and how much of that a snapshot still holds.

It reads the APFS extended attributes (`getattrlist(2)`) in one pass and keeps no state
between runs.

## Installation

Requires macOS and Zig 0.16.0 (pinned in `mise.toml`).

```sh
mise exec -- zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

## Usage

moira takes the flags of macOS `du`. On a terminal it prints every metric:

```console
$ moira -k -d1 clones
 allocated      share  exclusive     pinned  path
      2048       1024          0          0  clones/full
      2048       1280        512          0  clones/partial
      4096       2304        512          0  clones
```

Here `full` is a clone pair and `partial` a pair with 256 KiB of one side rewritten. `du`
reports 4096 KiB for both; they occupy 2304.

Piped, or with `--du`, moira prints `du` lines carrying one metric:

```sh
moira -sh ~/projects/*/target | sort -h
moira --exclusive -d1 -h ~/Library/Caches
```

## Metrics

| Flag | Column | Meaning |
|------|--------|---------|
| `--share` | share | the entry's portion of blocks shared through clones or hard links (default) |
| `--exclusive` | exclusive | blocks no other entry holds; freed by deletion once no snapshot holds them |
| `--pinned` | pinned | the part of exclusive a snapshot holds; freed when the snapshot expires |
| `--allocated` | allocated | what `du` reports |

Files deleted earlier appear in no column: the snapshot that still holds them has no path to
walk. `tmutil listlocalsnapshots /` lists the snapshots; removing them returns the space.

APFS reports sharing per file, not per block. A clone pair whose blocks were rewritten before
the latest snapshot is counted as pinned rather than shared, and blocks shared by some but not
all clones are split as if every clone held them.

## du compatibility

`moira --du --allocated` matches macOS `du` byte for byte across `-a -s -d -c -k -m -g -h
--si -A -B -l -I -t -x -H -L -P` and `BLOCKSIZE`; `tests/scrut/du-parity.md` checks each
against the system `du`. One deliberate difference: `du` prints nothing for a negative `-t`,
contrary to its manual; moira shows the directories smaller than the threshold.

## Agents

Coding agents reach for `du` and trust its numbers. moira ships a
[fas](https://github.com/srnnkls/fas) rule, `rules/fas/du.cue`, that answers every `du`
an agent runs with what `du` misses on APFS and the moira flag that covers it:

```cue
du_hint: {
	when: hook.#PreToolUse & tool.#Bash & (bash.#command & {#name: "du"})
	then: inject: {
		rule_id: "du-apfs-hint"
		channel: "agent"
		text:    "HINT: On APFS `du` charges every clone and hard link in full ..."
	}
}
```

The rule is offered through [phora](https://github.com/srnnkls/phora). Bind it into a
fas rules directory:

```toml
[sources.moira]
git = "https://github.com/srnnkls/moira.git"
branch = "main"
root = "rules/fas"

[targets.fas-rules]
path = "~/.config/fas/rules/moira"
sources.moira = { collapse = false }
```

## Performance

moira reads each directory with one `getattrlistbulk(2)` call and requests only the
attributes the printed metric needs. Warm cache, `hyperfine`, Apple silicon, macOS 26.5:

| Command | 38k files | 130k files |
|---------|----------:|-----------:|
| `du -s` | 192 ms | 1589 ms |
| `moira --allocated -s` | 137 ms | 1208 ms |
| `moira --share -s` | 166 ms | 1353 ms |
| `moira --columns -s` | 314 ms | 2128 ms |

The table reads every file's private size for the pinned column, which makes APFS walk
the file's extents.

## Development

```sh
mise run test                      # everything
mise run test --unit --integration  # any combination of --fmt, --unit, --integration
```
