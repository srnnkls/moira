# shellcheck shell=sh

_moira_fill() {
	mkdir -p "$(dirname "$1")"
	head -c "$2" /dev/zero | tr '\0' 'm' >"$1"
}

make_tree() {
	_moira_fill tree/small 100
	_moira_fill tree/sub/mid 1500000
	_moira_fill tree/big 3145728
	ln tree/big tree/big.link
	_moira_fill tree/obj.o 5000
	ln -s small tree/link
	_moira_fill tree/deep/a/b/c/file 20000
	mkdir -p tree/empty
	sync
}

make_clones() {
	_moira_fill clones/full/a 1048576
	cp -c clones/full/a clones/full/b
	_moira_fill clones/partial/a 1048576
	cp -c clones/partial/a clones/partial/b
	head -c 262144 /dev/zero | tr '\0' 'r' |
		dd of=clones/partial/b bs=262144 conv=notrunc 2>/dev/null
	sync
}

du_parity() {
	du "$@" >expected.out 2>&1
	moira --du --allocated "$@" 2>&1 | sed 's/^moira:/du:/' >actual.out
	diff expected.out actual.out
}
