-- Agent actions: start another agent like the one in the focused pane, or
-- fork the focused agent's chat into a side pane.
--
-- The actions only use Rex API calls and never run anything on this machine,
-- so they work the same for a session on a remote host: the new pane is
-- created on the host that holds the session, and the shell scripts below run
-- there, beside the agent they inspect.

local TERMINAL = "com.superlogical.terminal"
local SHELL_FLAVOR = "com.superlogical.terminal.shell"

-- Forks the Claude Code session of the process $1, read from the session
-- file Claude Code keeps per process. Tries the process's children too, for
-- installs where a wrapper process holds the terminal.
local CLAUDE_FORK = [[
pid=$1
dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
sid=
for p in "$pid" $(pgrep -P "$pid" 2>/dev/null); do
  f=$dir/sessions/$p.json
  [ -r "$f" ] || continue
  sid=$(sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' "$f" | head -n 1)
  [ -n "$sid" ] && break
done
if [ -n "$sid" ]; then
  # Name the fork after its parent, so the two can be told apart in the
  # resume picker.
  name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p' "$f" | head -n 1)
  exec claude --resume "$sid" --fork-session --name "fork: ${name:-$sid}"
fi
echo "Couldn't find the Claude Code session of process $pid. Pick the chat to fork:" >&2
exec claude --resume --fork-session
]]

-- Codex keeps no file per process, and a shared Codex app server usually
-- holds the chat, so nothing links a Codex process to its chat directly.
-- Look for the chat three ways, from the most certain to the least:
--   1. The rollout file the process holds open, when it holds the chat itself.
--   2. For a process that started a new chat (not `codex resume`): the chat
--      created in the same directory at the moment the process started.
--   3. The chat in the same directory whose name is the pane's title ($2).
--      A fork keeps its parent's name, so when several chats share the name,
--      take the one last updated closest to when the pane last changed state
--      ($3), which is when its last turn ended.
-- When none of them gives one answer, Codex's own picker asks.
local CODEX_FORK = [[
pid=$1
name=$2
changed=$(printf '%s' "$3" | tr -cd '0-9T:.+Z-')
dir=${CODEX_HOME:-$HOME/.codex}
uuid='[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}'

# Runs one query against the newest state database, printing one row per line.
query() {
  for db in $(ls -t "$dir"/state_*.sqlite 2>/dev/null); do
    if command -v sqlite3 >/dev/null 2>&1; then
      sqlite3 -readonly "$db" "$1" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c 'import sqlite3, sys
for row in sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True).execute(sys.argv[2]):
    print(row[0])' "$db" "$1" 2>/dev/null
    fi
    return
  done
}
quote() { printf '%s' "$1" | sed "s/'/''/g"; }

cwd=$(quote "$(pwd -P)")
sid=
for p in "$pid" $(pgrep -P "$pid" 2>/dev/null); do
  if [ -d "/proc/$p/fd" ]; then
    open=$(ls -l "/proc/$p/fd" 2>/dev/null)
  else
    open=$(lsof -p "$p" -Fn 2>/dev/null)
  fi
  sid=$(printf '%s\n' "$open" | sed -n "s/.*rollout-.*\($uuid\)\.jsonl.*/\1/p" | head -n 1)
  [ -n "$sid" ] && break
done
case " $(ps -o args= -p "$pid" 2>/dev/null) " in
  *" resume "*) resumed=1 ;;
  *) resumed= ;;
esac
if [ -z "$sid" ] && [ -z "$resumed" ]; then
  # ps prints the process's age as [[days-]hours:]minutes:seconds.
  age=$(ps -o etime= -p "$pid" 2>/dev/null | awk '{
    n = split($1, t, /[-:]/); s = 0; m[1] = 1; m[2] = 60; m[3] = 3600; m[4] = 86400
    for (i = 0; i < n; i++) s += t[n - i] * m[i + 1]
    print s }')
  if [ -n "$age" ]; then
    start=$(( $(date +%s) - age ))
    sid=$(query "select id from threads where cwd = '$cwd' and archived = 0 and created_at between $start - 5 and $start + 15 order by abs(created_at - $start) limit 1")
  fi
fi
if [ -z "$sid" ] && [ -n "$name" ]; then
  named="from threads where cwd = '$cwd' and archived = 0 and name = '$(quote "$name")'"
  found=$(query "select id $named")
  if [ "$(printf '%s\n' "$found" | grep -c .)" = 1 ]; then
    sid=$found
  elif [ -n "$found" ] && [ -n "$changed" ]; then
    sid=$(query "select id $named and abs(updated_at - strftime('%s', '$changed')) < 600 order by abs(updated_at - strftime('%s', '$changed')) limit 1")
  fi
fi
if [ -n "${AGENT_FORK_DRY_RUN:-}" ]; then
  echo "would fork: ${sid:-<picker>}"
  exit
fi
# Closing the pane hangs up this script and Codex with it. Note that it
# happened and carry on, so the fork can still be archived.
closed=
trap 'closed=1' HUP

# Codex can't name a fork as it creates it, and a fork keeps its parent's
# name. Once the forked Codex is ready for input, rename it from its own
# prompt, so the two can be told apart.
rename_fork() {
  command -v rex >/dev/null 2>&1 || return
  [ -n "$name" ] && [ -n "$REX_SESSION" ] && [ -n "$REX_BLOCK" ] || return
  tries=0
  while [ "$tries" -lt 40 ]; do
    sleep 0.5
    tries=$((tries + 1))
    rex block call -s "$REX_SESSION" -b "$REX_BLOCK" program_status 2>/dev/null |
      grep -q '"state":"idle"' || continue
    sleep 1
    rex send -s "$REX_SESSION" -b "$REX_BLOCK" "/rename fork: $name" &&
      rex send-key -s "$REX_SESSION" -b "$REX_BLOCK" enter
    return
  done
}

began=$(date +%s)
if [ -n "$sid" ]; then
  rename_fork >/dev/null 2>&1 &
  codex fork "$sid"
  until="and created_at <= $began + 30"
else
  echo "Couldn't find the Codex session of process $pid. Pick the chat to fork:" >&2
  codex fork
  until=
fi

# Codex has exited. A fork keeps its parent's name and nothing marks it as a
# fork, so kept forks pile up as look-alike chats. Ask whether to keep this
# one, and archive it otherwise. The fork is the chat Codex created in this
# directory when it started.
fork=$(query "select id || '|' || coalesce(nullif(title, ''), name, '') from threads where cwd = '$cwd' and archived = 0 and id != '$sid' and created_at >= $began - 2 $until order by created_at limit 1" | head -n 1)
fid=${fork%%|*}
[ -n "$fid" ] || exit 0

answer=
if [ -z "$closed" ]; then
  title=$(printf '%s' "${fork#*|}" | cut -c1-60)
  printf '\nKeep this fork%s? Archiving can be undone with "codex unarchive". [y/N] ' "${title:+ ($title)}"
  read -r answer
fi
if [ -n "$closed" ]; then
  # The pane was closed, so there is nowhere to ask. The agent_close action
  # asks before it closes the pane, and leaves this file to say "archive".
  # Without the file, keep the fork.
  marker=/tmp/rex-agent-fork-$(id -u)-${REX_BLOCK#block:}
  [ -e "$marker" ] || exit 0
  rm -f "$marker"
  codex archive "$fid" >/dev/null 2>&1
  exit 0
fi
case $answer in
  y|Y|yes|Yes) ;;
  *) codex archive "$fid" || { echo "Couldn't archive the fork $fid." >&2; sleep 5; } ;;
esac
]]

-- The agents these actions know. `names` are matched against the process in
-- the pane, and against the app name the agent reports to the terminal.
-- `new` is the command for a fresh agent. `fork` is a shell script that gets
-- the agent's process ID as $1. An agent without `fork` can't be forked.
local AGENTS = {
  { id = "claude", title = "Claude", names = { "claude", "claude-code" },
    new = { "claude" }, fork = CLAUDE_FORK },
  { id = "codex", title = "Codex", names = { "codex" },
    new = { "codex" }, fork = CODEX_FORK },
  { id = "gemini", title = "Gemini", names = { "gemini" }, new = { "gemini" } },
  { id = "opencode", title = "opencode", names = { "opencode" }, new = { "opencode" } },
}

local function basename(path)
  return (tostring(path):match("([^/]+)$") or ""):lower()
end

local function agent_named(name)
  if name == nil or name == "" then return nil end
  name = basename(name)
  for _, agent in ipairs(AGENTS) do
    for _, n in ipairs(agent.names) do
      if name == n then return agent end
    end
  end
  return nil
end

local function agent_of_process(proc)
  if type(proc) ~= "table" then return nil end
  return agent_named(proc.name) or agent_named(proc.argv0)
    or agent_named(proc.invoked_path) or agent_named(proc.path)
end

local function focused_block(ctx)
  if ctx.block_id ~= nil then return ctx.block_id end
  local view = rex.session.view{}
  if view == nil then return nil end
  for _, w in ipairs(view.windows or {}) do
    if w.window_id == view.active_window_id then return w.focused_block_id end
  end
  return nil
end

-- Finds the agent running in a block. Returns the block's ID, the agent, its
-- process ID, and its working directory, or raises an error the person sees.
local function find_agent(ctx)
  local block_id = focused_block(ctx)
  if block_id == nil then error("No pane is focused.", 0) end

  local info = rex.block.call(TERMINAL, "process", { block_id = block_id })
  if info == nil then error("The focused pane isn't a terminal.", 0) end

  -- The agent is usually the foreground process. It is an ancestor of the
  -- foreground process while it runs something of its own, such as an editor.
  local procs = { info.foreground }
  for _, p in ipairs(info.ancestors or {}) do procs[#procs + 1] = p end
  procs[#procs + 1] = info.child

  local agent, pid, cwd
  for _, p in ipairs(procs) do
    agent = agent_of_process(p)
    if agent ~= nil then
      pid, cwd = p.pid, p.cwd
      break
    end
  end

  -- Some installs run the agent under a name that says nothing, such as
  -- "node" or a version number. The app name the agent reports still does.
  if agent == nil then
    local status = rex.block.call(TERMINAL, "program_status", { block_id = block_id })
    for _, record in ipairs(status and status.records or {}) do
      agent = agent_named(record.effective_app) or agent_named(record.app)
      if agent ~= nil then
        pid = record.owner and record.owner.pid
        break
      end
    end
  end

  if agent == nil then
    error("No agent is running in the focused pane.", 0)
  end

  if cwd == nil and info.foreground ~= nil then cwd = info.foreground.cwd end
  if cwd == nil then
    local dir = rex.block.call(TERMINAL, "pwd", { block_id = block_id })
    cwd = dir and dir.pwd and dir.pwd:match("^file://[^/]*(/.*)$")
  end

  return block_id, agent, pid, cwd
end

local function terminal(label, command, cwd)
  return {
    block = {
      flavor = SHELL_FLAVOR,
      label = label,
      options = { command = command, cwd = cwd },
    },
  }
end

local SIDES = {
  right = { direction = "horizontal", side = "after" },
  left  = { direction = "horizontal", side = "before" },
  down  = { direction = "vertical", side = "after" },
  up    = { direction = "vertical", side = "before" },
}

-- Opens a layout in a split on one side of a block, and focuses it.
local function open_split(where, anchor_id, layout)
  local side = SIDES[where]
  if side == nil then
    error('"where" must be tab, right, left, down, or up.', 0)
  end
  local result, err = rex.session.new_split{
    anchor_id = anchor_id,
    direction = side.direction,
    side = side.side,
    layout = layout,
    focus = true,
  }
  if err ~= nil then error(err, 0) end
  return { block_id = result.block_ids and result.block_ids[1] }
end

-- The second half of agent_new for a tab. The app doesn't show a tab the
-- server opens for it, and it only learns of the tab once agent_new has
-- returned, so agent_new can't ask it to go there. This action runs after
-- that, when the app has the tab, and asks it then.
rex.action{
  name = "agent_show",
  title = "Agent: Show New Agent Tab",
  description = "Used by New Agent Like This One. Goes to the tab at a position.",
  category = "Agents",
  args = { index = "integer" },
  run = function(ctx, args)
    rex.exec({ "sleep", "0.15" })
    rex.client.queue("client.tab.goto", { index = args.index })
  end,
}

rex.action{
  name = "agent_new",
  title = "Agent: New Agent Like This One",
  description = "Start a fresh session of the agent running in the focused pane, in the same directory.",
  category = "Agents",
  keywords = "claude codex agent new spawn",
  args = { where = "string?" },
  run = function(ctx, args)
    local block_id, agent, _, cwd = find_agent(ctx)
    local where = args.where or "tab"
    if where ~= "tab" then
      return open_split(where, block_id, terminal(agent.id, agent.new, cwd))
    end

    local result, err = rex.session.new_window{
      layout = terminal(agent.id, agent.new, cwd),
      window_label = agent.title,
      focus = true,
    }
    if err ~= nil then error(err, 0) end

    local view = rex.session.view{}
    for index, w in ipairs(view and view.windows or {}) do
      if w.window_id == result.window_id then
        -- There is no app to ask when the action is run from the CLI.
        pcall(rex.client.queue, "agent_show", { index = index })
      end
    end
    return { block_id = result.block_ids and result.block_ids[1] }
  end,
}

rex.action{
  name = "agent_fork",
  title = "Agent: Fork Chat to Side Pane",
  description = "Open a copy of the focused agent's chat in a new pane. The original chat is left as it is.",
  category = "Agents",
  keywords = "claude codex agent fork side chat branch btw",
  args = { where = "string?" },
  run = function(ctx, args)
    local block_id, agent, pid, cwd = find_agent(ctx)
    if agent.fork == nil then
      error(agent.title .. " chats can't be forked from here.", 0)
    end
    if pid == nil then
      error("Couldn't find the " .. agent.title .. " process in the focused pane.", 0)
    end
    -- What the pane says about its chat, for agents whose chat can't be
    -- found from the process alone: the chat's name, which the agent puts
    -- first in the pane's title, and when the pane last changed state.
    local title = rex.block.call(TERMINAL, "title", { block_id = block_id })
    local name = title and title.title or ""
    name = name:match("^(.-) | ") or name
    local changed = ""
    local status = rex.block.call(TERMINAL, "program_status", { block_id = block_id })
    for _, record in ipairs(status and status.records or {}) do
      if record.owner and record.owner.pid == pid and record.updated_at then
        changed = record.updated_at
      end
    end
    local command = { "sh", "-c", agent.fork, "agent-fork", tostring(pid), name, changed }
    return open_split(args.where or "right", block_id,
      terminal(agent.id .. " fork", command, cwd))
  end,
}

-- Closes the focused pane, as the app's own Close does. For a Codex fork it
-- first asks whether to keep the fork. A closed pane can't ask, so the answer
-- is left for the fork's script: a file named after the pane, written on the
-- host that holds the session by a block that is never shown.
rex.action{
  name = "agent_close",
  title = "Agent: Close Pane",
  description = "Close the focused pane. For a Codex fork, ask first whether to keep the fork.",
  category = "Agents",
  run = function(ctx, args)
    -- Whatever goes wrong while asking, the pane must still close.
    local ok, cancelled = pcall(function()
      local block_id = focused_block(ctx)
      local view = rex.session.view{}
      local label
      for _, w in ipairs(view and view.windows or {}) do
        for _, layer in ipairs(w.layers or {}) do
          for _, b in ipairs(layer.blocks or {}) do
            if b.block_id == block_id then label = b.label end
          end
        end
      end
      if block_id == nil or label ~= "codex fork" then return false end

      local choice = rex.ui.pick{
        title = "Close Codex fork",
        items = {
          { id = "archive", title = "Archive this fork",
            subtitle = "Undo with codex unarchive" },
          { id = "keep", title = "Keep this fork" },
        },
      }
      if choice == nil then return true end
      if choice == "archive" then
        local uuid = block_id:gsub("^block:", "")
        rex.session.new_block{
          flavor = SHELL_FLAVOR,
          label = "fork cleanup",
          options = { command = {
            "sh", "-c", ': > "/tmp/rex-agent-fork-$(id -u)-$1"', "mark", uuid,
          } },
        }
        -- Give the file a moment to exist before the pane closes.
        rex.exec({ "sleep", "0.3" })
      end
      return false
    end)
    if ok and cancelled then return end
    rex.client.queue("client.close")
  end,
}

rex.bind("cmd+n", "agent_new")
rex.bind("shift+cmd+f", "agent_fork")
rex.bind("cmd+w", "agent_close")
