# cctray

cctray tracks coding agents' terminal sessions and account usage.

## Language

**Agent**: A supported coding tool, currently Claude or Codex.
_Avoid_: Provider when referring to the tool itself.

**Account**: The signed-in identity whose usage limits apply to an agent.

**Profile**: A saved, named account selection for an agent. Selecting a profile determines the account used for new sessions; running sessions keep their existing account.
_Avoid_: Account when referring specifically to the saved selection.

**Session**: An interactive agent running in a terminal. A session can contain multiple turns.
_Avoid_: Claude session when referring to sessions from either agent.

**Turn**: One period of agent work, ending in completion or interruption.

**Usage window**: A period with its own usage allowance and reset time. A session usage window is distinct from a terminal session.

**Pre-warm**: A small prompt that starts a new session usage window after the previous window resets, during configured active hours.
