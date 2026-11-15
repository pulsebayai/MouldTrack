#!/usr/bin/env bash
# MouldTrack production gate (PreToolUse/Bash).
# Reads the tool-call JSON on stdin. Exit 2 (blocked, reason on stderr) for:
#   pushes to main, prod/staging EAS releases, Supabase pushes to any non-dev project.
# Exit 0 otherwise. To proceed with a blocked action, the owner runs it himself
# or explicitly approves it in chat and runs it outside Claude.
set -u
INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try{const j=JSON.parse(s);process.stdout.write(String((j.tool_input&&j.tool_input.command)||""));}
  catch(e){process.stdout.write("");}
});')"
[ -z "$CMD" ] && exit 0

block() {
  echo "BLOCKED by production gate: $1" >&2
  echo "This needs the owner's explicit approval in this moment (AI-native SDLC rule 5). Ask Sidambara, then he runs it himself." >&2
  exit 2
}

# 1. git push to main (origin main, HEAD:main, refs/heads/main, +main, --all, --mirror)
if printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push\b'; then
  if printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+push\b[^;&|]*([[:space:]:+]|refs/heads/)main([[:space:]]|$|;|&|\|)'; then
    block "git push to main"
  fi
  if printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+push\b[^;&|]*--(all|mirror)\b'; then
    block "git push --all/--mirror (includes main)"
  fi
fi

# 2. EAS releases outside development
if printf '%s' "$CMD" | grep -Eq '\beas[[:space:]]+update\b[^;&|]*--(channel|branch)[=[:space:]]+(production|preview|staging)\b'; then
  block "EAS Update to a staging/production channel"
fi
if printf '%s' "$CMD" | grep -Eq '\beas[[:space:]]+deploy\b[^;&|]*--prod(uction)?\b'; then
  block "EAS Hosting production deploy"
fi
if printf '%s' "$CMD" | grep -Eq '\beas[[:space:]]+(build|submit)\b[^;&|]*--profile[=[:space:]]+(production|preview)\b'; then
  block "EAS build/submit with a staging/production profile"
fi

# 3. Supabase schema changes on hosted projects other than dev
if printf '%s' "$CMD" | grep -Eq '\bsupabase[[:space:]]+(db[[:space:]]+push|migration[[:space:]]+(up|repair)|db[[:space:]]+reset[^;&|]*--linked)\b'; then
  if printf '%s' "$CMD" | grep -Eq -- '--local\b|--db-url[=[:space:]]+[^[:space:]]*(localhost|127\.0\.0\.1)'; then
    exit 0
  fi
  DEV_REF="${DEV_SUPABASE_PROJECT_REF:-}"
  ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  LINKED="$(cat "$ROOT/supabase/.temp/project-ref" 2>/dev/null || true)"
  if [ -n "$DEV_REF" ] && [ "$LINKED" = "$DEV_REF" ] && ! printf '%s' "$CMD" | grep -Eq -- '--db-url'; then
    exit 0
  fi
  block "Supabase schema change on a non-dev (or unverified) project. Linked ref: '${LINKED:-none}', dev ref: '${DEV_REF:-unset}'"
fi
if printf '%s' "$CMD" | grep -Eq '\bsupabase[[:space:]]+db[[:space:]]+reset\b' && ! printf '%s' "$CMD" | grep -Eq -- '--local\b' && printf '%s' "$CMD" | grep -Eq -- '--db-url'; then
  block "supabase db reset against a remote database URL"
fi

exit 0
