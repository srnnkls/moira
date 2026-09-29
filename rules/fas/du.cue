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
		text:    "HINT: On APFS `du` charges every clone and hard link in full and cannot see space a snapshot holds. `moira` prints what du prints and takes its flags; add `-S` for each entry's fair share, `-E` for what deleting frees, `-p` for what a snapshot still holds, or `-C` for all of them."
	}
}
