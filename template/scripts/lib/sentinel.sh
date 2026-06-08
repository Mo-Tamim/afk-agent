#!/usr/bin/env bash
# Sentinel parsing: COMPLETE / NO_CHANGES / BLOCKED + optional payload blocks.
# Sourced by other scripts.

# Inspect a phase log and return the sentinel kind.
# Echoes one of: COMPLETE | NO_CHANGES | BLOCKED | NONE
afk::sentinel() {
  local log="$1"
  if grep -q "<promise>COMPLETE</promise>"   "$log"; then echo COMPLETE
  elif grep -q "<promise>NO_CHANGES</promise>" "$log"; then echo NO_CHANGES
  elif grep -q "<promise>BLOCKED</promise>"    "$log"; then echo BLOCKED
  else echo NONE
  fi
}

# Extract the one-line BLOCKED reason (the line immediately after the sentinel).
afk::blocked_reason() {
  local log="$1"
  awk '/<promise>BLOCKED<\/promise>/{flag=1; next} flag && NF{print; exit}' "$log"
}

# Extract a tagged payload block: <plan>...</plan>, <children>...</children>, <pr>...</pr>.
# Args: <log> <tag>
#
# NOTE: gawk reserves several verb-like names (`close`, `system`, `getline`).
# Use innocuous names (`o_tag`, `c_tag`) to stay portable across awk impls.
afk::payload() {
  local log="$1" tag="$2"
  awk -v o_tag="<$tag>" -v c_tag="</$tag>" '
    {
      if (!flag) {
        p = index($0, o_tag)
        if (!p) next
        flag = 1
        $0 = substr($0, p + length(o_tag))
      }
      e = index($0, c_tag)
      if (e) {
        print substr($0, 1, e - 1)
        exit
      }
      print
    }
  ' "$log"
}
