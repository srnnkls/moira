package moira

import (
	"github.com/srnnkls/fas/cue/bash"
	"github.com/srnnkls/fas/cue/hook"
	"github.com/srnnkls/fas/cue/tool"
)

du_hint: {
	when: hook.#PreToolUse & tool.#Bash & (bash.#command & {#name: "du"})
	then: inject: {
		rule_id: "du-apfs-hint"
		channel: "agent"
		text:    "HINT: On APFS `du` charges every clone and hard link in full and cannot see space a snapshot holds. `moira` takes du's flags: `moira --du -s PATH` reports each entry's fair share, `--exclusive` what deleting frees, `--pinned` what a snapshot still holds, and `moira --columns` shows all of them."
	}
}
