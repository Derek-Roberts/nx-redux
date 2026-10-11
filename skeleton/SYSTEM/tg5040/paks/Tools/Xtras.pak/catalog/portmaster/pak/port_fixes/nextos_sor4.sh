#!/bin/sh
# NX Redux port fix for NextOS Universal Ports' Streets of Rage 4 (sor4.zip),
# sourced by ports_launch.sh (see run_port_fixes there) with the launcher's
# ROM_PATH and PORTS_DIR set. Remove once NextOS fixes these upstream.

# The port runs a self-contained .NET host whose
# setup replaces LD_LIBRARY_PATH with "host_pkg/libs:/usr/lib:/lib", dropping
# PortMaster's ICU (lib/) and, on the Bricks, the firmware SDL2 (/usr/trimui/lib):
# .NET aborts on its first localized message and the host reports SDL2 missing.
# For that port only (other .NET ports keep PortMaster's ICU): run .NET without
# ICU and give host_pkg/libs a copy of the firmware SDL2 (no symlinks on exFAT).
nextos_sor4_pre() {
    local pkg="$PORTS_DIR/sor4/host_pkg"
    grep -q 'sor4host' "$ROM_PATH" 2>/dev/null && [ -f "$pkg/sor4host" ] || return 0
    NX_SOR4=1
    export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
    if [ ! -e /usr/lib/libSDL2-2.0.so.0 ] && [ -f /usr/trimui/lib/libSDL2-2.0.so.0 ] \
        && ! cmp -s /usr/trimui/lib/libSDL2-2.0.so.0 "$pkg/libs/libSDL2-2.0.so.0"; then
        cp -f /usr/trimui/lib/libSDL2-2.0.so.0 "$pkg/libs/"
    fi
}

# Its 1 GB / 2 GB setup bakes textures with a converter that reads every .xnb
# as a texture: the SpriteFont and shader ones fail its size checks ("texture
# conversion failed (reason 5)") and setup stops at the end of the bake, the
# same 18 files on every retry. Those files are meant to be copied unchanged:
# copy them from the APK into setup's resumable stage, mark them baked, and the
# launcher runs the port once more to finish. Returns 1 when there is nothing to fix.
nextos_sor4_retry() {
    local game="$PORTS_DIR/sor4" stage rel apk n=0
    stage="$game/.setup.stage"
    [ "${NX_SOR4:-0}" = 1 ] && [ -f "$stage/.setup_recipe" ] && [ ! -f "$stage/.assets_done" ] || return 1
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in /*|*..*) return 1 ;; esac
        mkdir -p "$(dirname "$stage/gameassets/$rel")" || return 1
        for apk in "$game"/*.apk "$game"/gamedata/*.apk; do
            [ -f "$apk" ] && unzip -p "$apk" "assets/$rel" > "$stage/gameassets/$rel.nxtmp" 2>/dev/null \
                && [ -s "$stage/gameassets/$rel.nxtmp" ] && break
        done
        [ -s "$stage/gameassets/$rel.nxtmp" ] || { rm -f "$stage/gameassets/$rel.nxtmp"; return 1; }
        mv -f "$stage/gameassets/$rel.nxtmp" "$stage/gameassets/$rel" \
            && printf '%s\n' "$rel" >> "$stage/.bake_progress" || return 1
        n=$((n + 1))
    done <<EOF
$(sed -n 's|^\[texconv\] ERR \([^:]*\): texture conversion failed (reason 5)$|\1|p' "$game/setup.log" 2>/dev/null | sort -u)
EOF
    [ "$n" -gt 0 ] || return 1
    echo "sor4: copied $n non-texture assets the converter rejects; resuming setup"
}
