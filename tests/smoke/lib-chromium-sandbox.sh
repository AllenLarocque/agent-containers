#!/usr/bin/env bash
# Sourced by tests/smoke/fetcher.sh and fetcher-offline.sh (not a smoke test itself).
# chromium_sandbox_state: is the running Chromium sandboxed? Judged from the kernel's view of the
# processes, not from Chromium's own word:
#   - the browser process (Chromium's binary, no --type=) carries no sandbox opt-out switch;
#   - at least one renderer is running, and EVERY renderer is in a user namespace and a PID namespace of
#     its own (not the browser's: Chromium's layer-1 namespace sandbox) and has more seccomp filters than
#     the browser (Chromium's own seccomp-BPF policy stacked on the container's: layer 2).
# Chromium's second zygote carries --no-zygote-sandbox by design (it forks the GPU and network
# processes, which are not namespace-sandboxed); renderers never come from it.
# Prints one line. Exit 0 = sandboxed; 1 = a renderer or the browser is NOT sandboxed (or opted out);
# 2 = no browser or no renderer running right now (nothing to judge).
chromium_sandbox_state() {
  local p exe c browser='' b_user='' b_pid='' b_filters='' n=0 r_user r_pid r_filters
  local -a renderers=()
  for p in /proc/[0-9]*; do
    exe=$(readlink "$p/exe" 2>/dev/null) || continue
    case $exe in */chrome-linux64/chrome) ;; *) continue ;; esac
    c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
    case $c in
      *--type=renderer*) renderers+=("$p") ;;
      *--type=*) ;;
      *) browser=$p ;;
    esac
  done
  [ -n "$browser" ] || { echo "no Chromium browser process"; return 2; }
  c=$(tr '\0' ' ' < "$browser/cmdline")
  if grep -qE -- '--no-sandbox|--disable-namespace-sandbox|--disable-seccomp-filter-sandbox|--disable-setuid-sandbox' <<<"$c"; then
    echo "the browser process carries a sandbox opt-out: $(grep -oE -- '--(no|disable)-[a-z-]*sandbox' <<<"$c" | sort -u | tr '\n' ' ')"; return 1
  fi
  b_user=$(readlink "$browser/ns/user") b_pid=$(readlink "$browser/ns/pid")
  b_filters=$(awk '/^Seccomp_filters:/{print $2}' "$browser/status")
  [ "${#renderers[@]}" -gt 0 ] || { echo "no renderer running yet"; return 2; }
  for p in "${renderers[@]}"; do
    r_user=$(readlink "$p/ns/user" 2>/dev/null) && r_pid=$(readlink "$p/ns/pid" 2>/dev/null) \
      && r_filters=$(awk '/^Seccomp_filters:/{print $2}' "$p/status" 2>/dev/null) || continue   # exited meanwhile
    if [ "$r_user" = "$b_user" ] || [ "$r_pid" = "$b_pid" ] || ! [ "${r_filters:-0}" -gt "${b_filters:-0}" ]; then
      echo "renderer ${p#/proc/} is NOT sandboxed (user ns $r_user vs browser $b_user, pid ns $r_pid vs $b_pid, seccomp filters $r_filters vs $b_filters)"
      return 1
    fi
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { echo "no renderer running yet"; return 2; }
  echo "browser: no opt-out; $n renderer(s): own user + PID namespaces, seccomp filters $r_filters (browser $b_filters)"
}
