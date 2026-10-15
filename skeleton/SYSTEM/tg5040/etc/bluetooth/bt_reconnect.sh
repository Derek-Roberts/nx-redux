#!/bin/sh
# Recall only the bonded, trusted audio sink connected before a stack stop (toggle or suspend).
# State is volatile: this deliberately does not change reconnect policy at boot.
BT_RECONNECT_STATE=${BT_RECONNECT_STATE:-/tmp/nx-bt-reconnect}

bt_valid_addr() {
	printf '%s\n' "$1" | LC_ALL=C grep -Eq '^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$'
}

bt_property_yes() {
	printf '%s\n' "$1" | awk -v key="$2" '
		{ sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
		$0 == key ": yes" { found=1 }
		END { exit !found }'
}

bt_audio_sink() {
	# Check a UUID property, not an arbitrary substring in a device name.
	printf '%s\n' "$1" | LC_ALL=C grep -Eqi '^[[:space:]]*UUID:.*\(0000110b-0000-1000-8000-00805f9b34fb\)[[:space:]]*$' || return 1
	# A hybrid HID device is a controller even if it advertises an audio UUID.
	! printf '%s\n' "$1" | LC_ALL=C grep -Eqi '^[[:space:]]*UUID:.*\(0000(1124|1812)-0000-1000-8000-00805f9b34fb\)[[:space:]]*$'
}

bt_token_current() {
	[ "${BT_RECONNECT_DISABLED:-0}" -eq 0 ] || return 1
	[ -n "${BT_RECONNECT_TOKEN:-}" ] || return 1
	[ "$(cat "$BT_RECONNECT_STATE/token" 2>/dev/null)" = "$BT_RECONNECT_TOKEN" ]
}

bt_now() {
	# A missing/invalid monotonic clock disables recall rather than extending it.
	{ IFS=' .' read -r bt_uptime bt_fraction bt_remainder < /proc/uptime; } 2>/dev/null || return 1
	case "$bt_uptime" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s\n' "$bt_uptime"
}

bt_set_deadline() {
	bt_clock=$(bt_now) || return 1
	BT_DEADLINE=$((bt_clock + $1))
}

bt_seconds_left() {
	bt_clock=$(bt_now) || return 1
	BT_WAIT=$((BT_DEADLINE - bt_clock))
	[ "$BT_WAIT" -gt 0 ] || return 1
	[ "$BT_WAIT" -le "$1" ] || BT_WAIT=$1
}

bt_toggle_begin() {
	# Atomic publication cancels any older worker before waiting for the stack lock.
	if [ ! -d "$BT_RECONNECT_STATE" ]; then
		(umask 077; mkdir "$BT_RECONNECT_STATE") || [ -d "$BT_RECONNECT_STATE" ] || return 1
	fi
	[ ! -L "$BT_RECONNECT_STATE" ] || return 1
	[ "$(ls -nd "$BT_RECONNECT_STATE" | awk '{print $3}')" = "$(id -u)" ] || return 1
	chmod 700 "$BT_RECONNECT_STATE" || return 1
	BT_RECONNECT_PREVIOUS_TOKEN=$(cat "$BT_RECONNECT_STATE/token" 2>/dev/null)
	BT_RECONNECT_TOKEN="$$.$(date +%s).$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
	(umask 077; printf '%s\n' "$BT_RECONNECT_TOKEN" > "$BT_RECONNECT_STATE/token.$$") || return 1
	mv -f "$BT_RECONNECT_STATE/token.$$" "$BT_RECONNECT_STATE/token" || return 1
	# The target BusyBox provides flock; the kernel drops this lock even on SIGKILL.
	busybox flock --help >/dev/null 2>&1 || return 1
	[ ! -d "$BT_RECONNECT_STATE/lock" ] && [ ! -L "$BT_RECONNECT_STATE/lock" ] || return 1
	(umask 077; touch "$BT_RECONNECT_STATE/lock") || return 1
	chmod 600 "$BT_RECONNECT_STATE/lock" || return 1
	exec 9>"$BT_RECONNECT_STATE/lock" || return 1
	bt_lock_tries=0
	while ! busybox flock -n 9; do
		if ! bt_token_current; then
			exec 9>&-
			return 2
		fi
		bt_lock_tries=$((bt_lock_tries + 1))
		if [ "$bt_lock_tries" -ge 200 ]; then
			exec 9>&-
			echo "Bluetooth toggle busy" >&2
			return 3
		fi
		sleep 0.1
	done
	bt_token_current || return 2
}

bt_current_pid() {
	# Builtin read opens proc/self for this shell, including command substitutions.
	{ IFS= read -r bt_self_stat < /proc/self/stat; } 2>/dev/null || return 1
	BT_CURRENT_PID=${bt_self_stat%% *}
}

bt_process_identity() {
	BT_PROCESS_IDENTITY=
	bt_identity_pid=$1
	bt_identity_parent=$2
	{ IFS= read -r bt_proc_stat < "/proc/$bt_identity_pid/stat"; } 2>/dev/null || return 1
	[ "${bt_proc_stat%% *}" = "$bt_identity_pid" ] || return 1
	# Strip the complete parenthesized comm field, which may contain spaces.
	bt_proc_fields=${bt_proc_stat##*) }
	set -- $bt_proc_fields
	[ -z "$bt_identity_parent" ] || [ "$2" = "$bt_identity_parent" ] || return 1
	[ "$#" -ge 20 ] || return 1
	shift 19
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	BT_PROCESS_IDENTITY=$1
}

bt_daemon_identity() {
	BT_DAEMON_IDENTITY=
	# BusyBox pgrep -x can miss a running bluetoothd on this firmware.
	bt_daemon_pid=$(pidof bluetoothd) || return 1
	case "$bt_daemon_pid" in ''|*[!0-9]*) return 1 ;; esac
	# pidof matches the executable name; require the kernel's exact comm too.
	{ IFS= read -r bt_daemon_comm < "/proc/$bt_daemon_pid/comm"; } 2>/dev/null || return 1
	[ "$bt_daemon_comm" = bluetoothd ] || return 1
	bt_process_identity "$bt_daemon_pid" "" || return 1
	BT_DAEMON_IDENTITY="$bt_daemon_pid:$BT_PROCESS_IDENTITY"
}

bt_kill_identity() {
	[ -n "$3" ] || return 1
	bt_process_identity "$1" "$2" || return 1
	[ "$BT_PROCESS_IDENTITY" = "$3" ] || return 1
	kill -KILL "$1" 2>/dev/null
}

# bluetoothctl starts its internal timeout after readiness and may buffer
# output until it expires. Use one external deadline for the exact child.
bt_run_bounded() {
	bt_limit=$1
	shift
	bt_current_pid || return 1
	bt_parent=$BT_CURRENT_PID
	(exec 9>&-; exec "$@") &
	bt_child=$!
	if ! bt_process_identity "$bt_child" "$bt_parent"; then
		# The child is still ours and unreaped; never wait indefinitely without
		# a watchdog whose process identity we can verify.
		kill -KILL "$bt_child" 2>/dev/null
		wait "$bt_child" 2>/dev/null
		return 1
	fi
	bt_child_identity=$BT_PROCESS_IDENTITY
	(
		exec 9>&-
		busybox sleep "$bt_limit"
		bt_kill_identity "$bt_child" "$bt_parent" "$bt_child_identity"
	) >/dev/null 2>&1 &
	bt_watchdog=$!
	if ! bt_process_identity "$bt_watchdog" "$bt_parent"; then
		kill -KILL "$bt_child" "$bt_watchdog" 2>/dev/null
		wait "$bt_child" "$bt_watchdog" 2>/dev/null
		return 1
	fi
	bt_watchdog_identity=$BT_PROCESS_IDENTITY
	wait "$bt_child" 2>/dev/null
	bt_result=$?
	bt_kill_identity "$bt_watchdog" "$bt_parent" "$bt_watchdog_identity"
	wait "$bt_watchdog" 2>/dev/null
	return "$bt_result"
}

bt_ctl() {
	bt_limit=$1
	shift
	bt_run_bounded "$bt_limit" bluetoothctl "$@"
}

bt_capture_audio() {
	bt_token_current || return 0
	# Only this stop can arm the next start; never retain an earlier selection.
	rm -f "$BT_RECONNECT_STATE/audio"
	bt_set_deadline 6 || return 0
	bt_seconds_left 2 || return 0
	bt_show=$(bt_ctl "$BT_WAIT" show 2>/dev/null)
	bt_property_yes "$bt_show" Powered || return 0
	bt_token_current || return 0
	bt_seconds_left 2 || return 0
	bt_devices=$(bt_ctl "$BT_WAIT" devices Connected 2>/dev/null) || return 0
	bt_selected=
	for bt_addr in $(printf '%s\n' "$bt_devices" | awk '$1 == "Device" {print $2}'); do
		bt_token_current && bt_seconds_left 2 || { rm -f "$BT_RECONNECT_STATE/audio"; return 0; }
		bt_valid_addr "$bt_addr" || continue
		bt_info=$(bt_ctl "$BT_WAIT" info "$bt_addr" 2>/dev/null) || return 0
		if bt_property_yes "$bt_info" Connected && bt_property_yes "$bt_info" Bonded &&
			bt_property_yes "$bt_info" Trusted && bt_audio_sink "$bt_info"; then
			# Multiple connected sinks are ambiguous; do not choose by list order.
			[ -z "$bt_selected" ] || return 0
			bt_selected=$bt_addr
		fi
	done
	bt_token_current || return 0
	if [ -n "$bt_selected" ]; then
		(umask 077; printf '%s %s\n' "$BT_RECONNECT_TOKEN" "$bt_selected" > "$BT_RECONNECT_STATE/audio.$$") &&
			mv -f "$BT_RECONNECT_STATE/audio.$$" "$BT_RECONNECT_STATE/audio"
	fi
}

bt_prepare_reconnect() {
	BT_RECONNECT_TARGET=
	bt_token_current || return 1
	[ -f "$BT_RECONNECT_STATE/audio" ] && [ ! -L "$BT_RECONNECT_STATE/audio" ] || return 1
	read -r bt_capture_token bt_addr bt_extra < "$BT_RECONNECT_STATE/audio" || return 1
	rm -f "$BT_RECONNECT_STATE/audio" || return 1
	[ -z "$bt_extra" ] && [ "$bt_capture_token" = "$BT_RECONNECT_PREVIOUS_TOKEN" ] || return 1
	bt_valid_addr "$bt_addr" || return 1
	BT_RECONNECT_TARGET=$bt_addr
}

bt_reconnect_log() {
	logger -t nx-bt-reconnect "$1" 2>/dev/null || :
}

bt_worker_current() {
	bt_token_current && return 0
	bt_reconnect_log "cancelled by a newer Bluetooth request"
	return 1
}

bt_worker_time_left() {
	bt_seconds_left "$1" && return 0
	bt_reconnect_log "30-second reconnect window exhausted"
	return 1
}

bt_worker_connect() {
	bt_addr=$1
	exec 9>"$BT_RECONNECT_STATE/lock" || return 1
	# A stop publishes its new token before taking this same lock. Once we
	# acquire it, check again and hold it through the bounded Connect call.
	while ! busybox flock -n 9; do
		bt_worker_current && bt_worker_time_left 1 || { exec 9>&-; return 1; }
		sleep 0.1
	done
	bt_worker_current && bt_worker_time_left 8 && bt_daemon_identity &&
		[ "$BT_DAEMON_IDENTITY" = "$BT_RECONNECT_DAEMON_IDENTITY" ] || { exec 9>&-; return 1; }
	bt_ctl "$BT_WAIT" connect "$bt_addr" >/dev/null 2>&1
	bt_result=$?
	exec 9>&-
	return "$bt_result"
}

bt_reconnect_audio() {
	BT_RECONNECT_TOKEN=$1
	bt_addr=$2
	BT_RECONNECT_DAEMON_IDENTITY=$3
	bt_valid_addr "$bt_addr" && bt_worker_current || return 0
	bt_reconnect_log "starting bounded audio recall"
	# One bounded window per stack start; never compete continuously with phones.
	bt_set_deadline 30 || return 0
	bt_ready_deadline=$((bt_clock + 10))
	bt_ready=0
	while bt_worker_current && bt_worker_time_left 1; do
		bt_show=$(bt_ctl "$BT_WAIT" show 2>/dev/null)
		if bt_property_yes "$bt_show" Powered &&
			bt_run_bounded 1 dbus-send --system --print-reply --reply-timeout=1000 \
			--dest=org.freedesktop.DBus /org/freedesktop/DBus \
			org.freedesktop.DBus.NameHasOwner string:org.bluealsa 2>/dev/null |
			grep -q 'boolean true'; then
			bt_ready=1
			break
		fi
		bt_clock=$(bt_now) && [ "$bt_clock" -lt "$bt_ready_deadline" ] || break
		sleep 1
	done
	[ "$bt_ready" -eq 1 ] || { bt_reconnect_log "adapter or BlueALSA readiness timed out"; return 0; }
	bt_attempt=0
	while [ "$bt_attempt" -lt 2 ] && bt_worker_current && bt_worker_time_left 2; do
		bt_info=$(bt_ctl "$BT_WAIT" info "$bt_addr" 2>/dev/null)
		bt_property_yes "$bt_info" Bonded && bt_property_yes "$bt_info" Trusted &&
			bt_audio_sink "$bt_info" || { bt_reconnect_log "saved audio device no longer bonded and trusted"; return 0; }
		bt_property_yes "$bt_info" Connected && { bt_reconnect_log "connection confirmed"; return 0; }
		bt_reconnect_log "connect attempt $((bt_attempt + 1))"
		bt_worker_connect "$bt_addr" || bt_worker_current || return 0
		# bluetoothctl can exit successfully after an HCI failure: inspect state.
		bt_worker_current && bt_worker_time_left 2 || return 0
		bt_info=$(bt_ctl "$BT_WAIT" info "$bt_addr" 2>/dev/null)
		bt_property_yes "$bt_info" Connected && { bt_reconnect_log "connection confirmed"; return 0; }
		bt_attempt=$((bt_attempt + 1))
		[ "$bt_attempt" -lt 2 ] && sleep 1
	done
	bt_reconnect_log "two connect attempts exhausted"
	return 0
}

# The file is normally sourced by bt_init.sh; only workers execute this mode.
if [ "$1" = reconnect_worker ]; then
	bt_reconnect_audio "$2" "$3" "$4"
fi
