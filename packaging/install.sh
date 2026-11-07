#!/bin/sh
# PadLink's macOS/Linux installer. Downloads are verified before execution.
set -efu
umask 077
repository=sam-eer12/prod
prefix=${PADLINK_INSTALL_PREFIX:-"$HOME/.local"}
version=
source_folder=
state_dir=
add_path=0
uninstall=0

fail() { printf 'padlink installer: %s\n' "$*" >&2; exit 1; }
usage() {
    printf '%s\n' 'Usage: sh install.sh [--prefix ABSOLUTE_PATH] [--version VERSION] [--add-to-path] [--from RELEASE_FOLDER] [--state-dir ABSOLUTE_PATH] [--uninstall]'
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix|--version|--from|--state-dir)
            [ "$#" -ge 2 ] || fail "$1 needs a value"
            case "$1" in --prefix) prefix=$2;; --version) version=$2;; --from) source_folder=$2;; --state-dir) state_dir=$2;; esac
            shift 2;;
        --add-to-path) add_path=1; shift;;
        --uninstall) uninstall=1; shift;;
        --help|-h) usage; exit 0;;
        *) usage; fail "unknown option: $1";;
    esac
done
case "$prefix" in /*) ;; *) fail '--prefix must be an absolute path';; esac
[ "$(id -u)" -ne 0 ] || fail 'run this as your normal user, without sudo'
if [ "$uninstall" -eq 1 ]; then
    [ -f "$prefix/share/padlink/install.json" ] || fail 'no managed installation exists at this prefix'
    set -- "$prefix/bin/padlink" uninstall
    [ -z "$state_dir" ] || set -- "$@" --state-dir "$state_dir"
    exec "$@"
fi
for tool in curl tar openssl awk sed mktemp; do command -v "$tool" >/dev/null 2>&1 || fail "install the required tool: $tool"; done
case "$(uname -s)" in
    Darwin)
        machine=$(uname -m)
        if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || printf 0)" = 1 ]; then machine=arm64; fi
        case "$machine" in arm64|aarch64) target=aarch64-apple-darwin;; x86_64) target=x86_64-apple-darwin;; *) fail 'unsupported macOS CPU';; esac
        major=$(sw_vers -productVersion | awk -F. '{print $1}')
        [ "$major" -ge 13 ] || fail 'macOS 13 or later is required';;
    Linux)
        case "$(uname -m)" in aarch64|arm64) target=aarch64-unknown-linux-musl;; x86_64|amd64) target=x86_64-unknown-linux-musl;; *) fail 'unsupported Linux CPU';; esac;;
    *) fail 'use install.ps1 for native Windows; supported shell hosts are macOS and Linux';;
esac
stage=$(mktemp -d "${TMPDIR:-/tmp}/padlink-install.XXXXXXXX") || fail 'could not create a private download directory'
trap 'rm -rf "$stage"' EXIT
trap 'exit 130' HUP INT TERM

cat > "$stage/public.pem" <<'PADLINK_PUBLIC_KEY'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAw5SekQok9rYWdfb9VQjO
UeQ47Me0ZsQI6y2uXHqqSD/GBves7fsugntsaPLfJO5ngvpYH7nGdycC4AtbeJ8+
f/D5BYjWWHRNdf0v/siI+NgSaKNdDcy7r4ek+dVln4B7g+taezzGaVsQrUvnGnIp
wlswsTaXAFZwuB5bS3fPhdhCboBgUYFZIAEOl7nIVQMmKdbudl9JLB846u6mEGTc
OybtyyXAVGoMQ3w7SGthJFuL99nzeI+QYrKjGw3GOtML3Bom185VzBNKOAwmYUtT
bMiawQN3wd71qlg+M98OIv6JaqhhSN8W9qGUIAMaIYz/XyljjE6GFtJGfFSPvD1P
PCBATShYyNKjypisq6crQu3f2xwIjBaC369lO8P2nisoWLhpK4cIrYBTRomI561b
/i1VVxiTbO0xPb0uWLiaUOOvXf6xOEq5HKCs9cmVf7alIlGTuSEfBZyVnUO4NDYz
Z2Tm9WOOX/QLk0VvsWnLz3+Pjjt65TWS1TvRtV1LjNsNAgMBAAE=
-----END PUBLIC KEY-----
PADLINK_PUBLIC_KEY

fetch() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 120 --retry 2 --max-filesize "$3" --output "$2" "$1"
}
base="https://github.com/$repository/releases/latest/download"
if [ -n "$version" ]; then
    case "$version" in *[!0-9A-Za-z.+-]*|'') fail 'invalid version';; esac
    base="https://github.com/$repository/releases/download/v$version"
fi
if [ -n "$source_folder" ]; then
    cp "$source_folder/release-manifest.txt" "$stage/release-manifest.txt"
    cp "$source_folder/release-manifest.sig" "$stage/release-manifest.sig"
else
    fetch "$base/release-manifest.txt" "$stage/release-manifest.txt" 65536 || fail 'release metadata download failed'
    fetch "$base/release-manifest.sig" "$stage/release-manifest.sig" 512 || fail 'release signature download failed'
fi
[ "$(wc -c < "$stage/release-manifest.txt")" -le 65536 ] || fail 'release manifest is too large'
[ "$(wc -c < "$stage/release-manifest.sig")" -le 512 ] || fail 'release signature is too large'
openssl dgst -sha256 -verify "$stage/public.pem" -signature "$stage/release-manifest.sig" "$stage/release-manifest.txt" >/dev/null 2>&1 || fail 'release signature verification failed'
[ "$(sed -n '1p' "$stage/release-manifest.txt")" = 'PADLINK_RELEASE 1' ] || fail 'unsupported release metadata'
published=$(sed -n '2s/^version //p' "$stage/release-manifest.txt")
case "$published" in *[!0-9A-Za-z.+-]*|'') fail 'invalid published version';; esac
[ -z "$version" ] || [ "$version" = "$published" ] || fail 'published version differs from the requested version'
record=$(awk -v target="$target" '$1 == "artifact" && $2 == target {print}' "$stage/release-manifest.txt")
# The signed, whitespace-delimited record is intentionally split with globbing disabled.
# shellcheck disable=SC2086
set -- $record
[ "$#" -eq 10 ] || fail 'release has no unique artifact for this OS/CPU'
archive=$3; bytes=$4; checksum=$5; entry=$9; url=${10}
[ "$archive" = "padlink-$published-$target.tar.gz" ] || fail 'unexpected archive filename'
[ "$entry" = padlink ] || fail 'unexpected binary filename'
[ "$url" = "https://github.com/$repository/releases/download/v$published/$archive" ] || fail 'unexpected artifact origin'
case "$bytes" in *[!0-9]*|'') fail 'invalid archive size';; esac
if [ "$bytes" -le 0 ] || [ "$bytes" -gt 32000000 ]; then fail 'archive exceeds size limits'; fi
if [ -n "$source_folder" ]; then cp "$source_folder/$archive" "$stage/$archive"; else fetch "$url" "$stage/$archive" "$bytes" || fail 'archive download failed'; fi
[ "$(wc -c < "$stage/$archive")" -eq "$bytes" ] || fail 'archive size verification failed'
actual=$(openssl dgst -sha256 -r "$stage/$archive" | awk '{print $1}')
[ "$actual" = "$checksum" ] || fail 'archive checksum verification failed'
[ "$(tar -tzf "$stage/$archive")" = padlink ] || fail 'archive must contain exactly the flat padlink binary'
[ "$(tar -tvzf "$stage/$archive" | awk '{print substr($1, 1, 1)}')" = '-' ] || fail 'archive binary must be a regular file'
tar -xzf "$stage/$archive" -C "$stage" -- padlink
chmod 755 "$stage/padlink"
set -- "$stage/padlink" _install --prefix "$prefix" --from "$stage"
[ -z "$state_dir" ] || set -- "$@" --state-dir "$state_dir"
"$@"

if [ "$add_path" -eq 1 ]; then
    case "${SHELL:-}" in */zsh) rc="$HOME/.zshrc";; */bash) rc="$HOME/.bashrc";; *) fail 'automatic PATH setup supports zsh/bash; add the printed bin directory to your shell PATH manually';; esac
    quoted=$(printf '%s' "$prefix/bin" | sed "s/'/'\\\\''/g")
    line="export PATH='$quoted':\"\$PATH\" # PadLink managed PATH"
    if [ ! -f "$rc" ] || ! awk -v line="$line" '$0 == line {found=1} END {exit !found}' "$rc"; then
        printf '\n%s\n' "$line" >> "$rc"
    fi
    printf 'PATH configured in %s. Open a new terminal, or run: . "%s"\n' "$rc" "$rc"
fi
printf 'Ready: padlink --version; padlink daemon start; padlink update\n'
