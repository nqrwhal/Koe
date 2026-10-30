#!/bin/sh
# Installs or updates Koe, including its speech and language models.
#   curl -fsSL https://raw.githubusercontent.com/nqrwhal/Koe/main/install.sh | sh
#
#   KOE_INSTALL_DIR=…   install somewhere other than /Applications (or ~/Applications); doesn't launch
#   KOE_SKIP_MODELS=1   skip the models now; Koe downloads them the first time it opens
#   KOE_ZIP_URL=…       install from another Koe.zip (for testing a build)
set -eu

url="${KOE_ZIP_URL:-https://github.com/nqrwhal/Koe/releases/latest/download/Koe.zip}"

# ── Look ────────────────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    tty=1
    esc=$(printf '\033')
    reset="$esc[0m" dim="$esc[2m" bold="$esc[1m" clear="$esc[2K"
    seal="$esc[38;5;203m" green="$esc[38;5;114m" grey="$esc[38;5;239m" text="$esc[38;5;252m" quiet="$esc[38;5;245m"
else
    tty=0 esc="" reset="" dim="" bold="" clear="" seal="" green="" grey="" text="" quiet=""
fi

say() { printf '%s\n' "$*"; }
ok() { say "  ${green}✓${reset} ${text}$*${reset}"; }
fail() { say "  ${seal}✗ $*${reset}" >&2; exit 1; }

banner() {
    # 声 ("koe", voice), drawn from Hiragino Sans by tools/make-banner.swift, in seal-red shades.
    set -- 209 209 209 203 203 203 202 202 166 166 160 160
    while IFS= read -r line; do
        if [ "$tty" = 1 ]; then printf '  %s[38;5;%sm%s%s\n' "$esc" "$1" "$line" "$reset"; else printf '  %s\n' "$line"; fi
        shift
    done <<'ART'
                     ▄▄▄▄
   ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄████▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
  ▀██████████████████████████████████████████▀
      ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄████▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
      ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
       ▄████████████████████████████████▄
       ████▀▀▀▀▀▀▀▀▀▀████▀▀▀▀▀▀▀▀▀▀▀▀████
       ████▄▄▄▄▄▄▄▄▄▄████▄▄▄▄▄▄▄▄▄▄▄▄████
      ████▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀█████
     ████▀                           ▀▀▀
  ▄█████▀
 ▀███▀▀
ART
    say ""
    say "  ${bold}${text}Koe${reset} ${seal}声${reset}  ${quiet}hold-to-talk dictation that stays on your Mac${reset}"
    say ""
}

size() { awk -v b="$1" 'BEGIN { if (b >= 1e9) printf "%.1f GB", b / 1e9; else printf "%.0f MB", b / 1e6 }'; }

# bar <fraction> <colour>: a 26-cell bar, filled part in <colour>.
bar() {
    awk -v f="$1" -v on="$2" -v off="$grey" -v reset="$reset" 'BEGIN {
        n = int(f * 26 + 0.5); if (n > 26) n = 26
        s = on; for (i = 0; i < n; i++) s = s "━"
        s = s off; for (; i < 26; i++) s = s "━"
        printf "%s%s", s, reset }'
}

spinner() { awk -v i="$1" 'BEGIN { split("⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏", f, " "); printf "%s", f[i % 10 + 1] }'; }

# row <icon> <name> <fraction> <bar colour> <note>
row() {
    pct=$(awk -v f="$3" 'BEGIN { printf "%3d%%", f * 100 }')
    printf '\r%s  %s %s%-24s%s %s %s%s%s  %s%s%s\n' "$clear" "$1" "$text" "$2" "$reset" \
        "$(bar "$3" "$4")" "$quiet" "$pct" "$reset" "$quiet" "$5" "$reset"
}

tmp=$(mktemp -d)
cleanup() { [ "$tty" = 1 ] && printf '%s[?25h' "$esc"; rm -rf "$tmp"; }
trap cleanup EXIT
trap 'say ""; say "  ${quiet}Stopped. Run the installer again any time; Koe also finishes downloading on first launch.${reset}"; exit 130' INT

banner

# ── Check the Mac ───────────────────────────────────────────────────────────────────────
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail "Koe needs a Mac with Apple Silicon."
macos=$(sw_vers -productVersion)
[ "${macos%%.*}" -ge 15 ] || fail "Koe needs macOS 15 or later (this Mac has $macos)."
chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")
ok "$chip · macOS $macos"

dir="${KOE_INSTALL_DIR:-/Applications}"
if [ -z "${KOE_INSTALL_DIR:-}" ] && [ ! -w /Applications ]; then dir="$HOME/Applications"; fi
mkdir -p "$dir"
previous=""
if [ -f "$dir/Koe.app/Contents/Info.plist" ]; then
    previous=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$dir/Koe.app/Contents/Info.plist" 2>/dev/null || true)
fi

# ── Download the app ────────────────────────────────────────────────────────────────────
total=$(curl -fsSIL "$url" | awk 'tolower($1) == "content-length:" { n = $2 } END { gsub(/\r/, "", n); print n + 0 }')
curl -fsSL "$url" -o "$tmp/Koe.zip" &
pid=$!
if [ "$tty" = 1 ]; then
    printf '%s[?25l' "$esc"
    tick=0
    while kill -0 "$pid" 2>/dev/null; do
        have=$(stat -f%z "$tmp/Koe.zip" 2>/dev/null || echo 0)
        frac=$(awk -v h="$have" -v t="$total" 'BEGIN { printf "%.4f", (t > 0 ? h / t : 0) }')
        row "${seal}$(spinner $tick)${reset}" "Koe app" "$frac" "$seal" "$(size "$have") / $(size "$total")"
        printf '%s[1A' "$esc"
        tick=$((tick + 1))
        sleep 0.1
    done
    printf '\r%s' "$clear"
fi
wait "$pid" || fail "Couldn't download Koe from $url. Check your connection and try again."
ditto -x -k "$tmp/Koe.zip" "$tmp"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$tmp/Koe.app/Contents/Info.plist")
ok "Downloaded Koe $version ($(size "$(stat -f%z "$tmp/Koe.zip")"))"

pkill -x Koe 2>/dev/null || true
rm -rf "$dir/Koe.app"
mv "$tmp/Koe.app" "$dir/Koe.app"
if [ -n "$previous" ] && [ "$previous" != "$version" ]; then
    ok "Updated $dir/Koe.app from $previous to $version"
else
    ok "Installed $dir/Koe.app"
fi

# ── Download the models ─────────────────────────────────────────────────────────────────
# Releases before 0.3 can't do this; they download their models on first launch instead.
case "$version" in 0.1 | 0.1.* | 0.2 | 0.2.*) KOE_SKIP_MODELS=1 ;; esac
if [ "${KOE_SKIP_MODELS:-}" != 1 ]; then
    say ""
    say "  ${text}Models${reset} ${quiet}· about 5.9 GB, downloaded once and kept on this Mac${reset}"
    : > "$tmp/failed"
    "$dir/Koe.app/Contents/MacOS/Koe" --install-models 2>/dev/null </dev/null | {
        set +e  # the checks below are expected to be false most of the time
        ids="" rows=0 tick=0
        draw() {
            [ "$rows" -gt 0 ] && printf '%s[%sA' "$esc" "$rows"
            rows=0
            for id in $ids; do
                rows=$((rows + 1))
                eval "name=\$name_$id bytes=\$bytes_$id frac=\$frac_$id state=\$state_$id"
                case $state in
                    done) row "${green}✓${reset}" "$name" 1 "$seal" "$(size "$bytes")" ;;
                    fail) row "${seal}✗${reset}" "$name" "$frac" "$grey" "will finish on first launch" ;;
                    wait) row "${grey}·${reset}" "$name" 0 "$grey" "$(size "$bytes")" ;;
                    *) if awk -v f="$frac" 'BEGIN { exit !(f >= 0.999) }'; then note="preparing…"
                       else note="$(size "$(awk -v f="$frac" -v b="$bytes" 'BEGIN { printf "%d", f * b }')") / $(size "$bytes")"; fi
                       row "${seal}$(spinner $tick)${reset}" "$name" "$frac" "$seal" "$note" ;;
                esac
            done
        }
        while read -r kind id rest; do
            case $kind in
                model)
                    ids="$ids $id"
                    eval "name_$id=\"\${rest#* }\" bytes_$id=\${rest%% *} frac_$id=0 state_$id=wait" ;;
                progress)
                    eval "[ \"\$state_$id\" = wait ] && state_$id=run; [ \"\$state_$id\" = run ] && frac_$id=$rest"
                    [ "$tty" = 0 ] && eval "[ -z \"\${told_$id:-}\" ]" && { eval "told_$id=1; say \"  Downloading \${name_$id}…\""; } ;;
                done) eval "state_$id=done frac_$id=1"; [ "$tty" = 0 ] && eval "say \"  ✓ \$name_$id\"" ;;
                fail) eval "state_$id=fail"; echo "$id" >> "$tmp/failed"; [ "$tty" = 0 ] && eval "say \"  ✗ \$name_$id: $rest\"" ;;
                *) continue ;;
            esac
            # Draw once every model is announced (they all come first), then redraw in place.
            if [ "$tty" = 1 ] && [ "$kind" != model ]; then printf '%s[?25l' "$esc"; draw; tick=$((tick + 1)); fi
        done
    }
    [ "$tty" = 1 ] && printf '%s[?25h' "$esc"
    if [ -s "$tmp/failed" ]; then
        say "  ${quiet}Some models didn't download; Koe will finish them the first time it opens.${reset}"
    fi
fi

# ── Done ────────────────────────────────────────────────────────────────────────────────
say ""
if [ -z "${KOE_INSTALL_DIR:-}" ]; then
    open "$dir/Koe.app"
    say "  ${seal}声${reset} ${bold}${text}Koe is ready.${reset} ${text}Look for 声 in your menu bar.${reset}"
else
    say "  ${seal}声${reset} ${bold}${text}Koe is installed.${reset}"
fi
say ""
say "  ${quiet}1.${reset} ${text}Allow Accessibility and Microphone access when macOS asks.${reset}"
say "  ${quiet}2.${reset} ${text}Hold ${bold}Right ⌘${reset}${text}, speak, and let go. The text appears where your cursor is.${reset}"
say "  ${quiet}3.${reset} ${text}Add your own names and terms to ${reset}${quiet}~/Library/Application Support/Koe/vocabulary.txt${reset}"
say ""
