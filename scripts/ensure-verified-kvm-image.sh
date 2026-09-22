#!/usr/bin/env bash
# Download a KVM image only through HTTPS and publish it atomically after its
# expected digest has been verified. It is intentionally usable outside
# Terraform so operators can independently validate the retained cache.
set -euo pipefail

usage() {
  printf 'Usage: %s --url HTTPS_URL --digest ALGORITHM:HEX --destination ABSOLUTE_PATH\n' "${0##*/}" >&2
  exit 64
}

url=''
digest=''
destination=''
while [ "$#" -gt 0 ]; do
  case "$1" in
  --url)
    url=${2:?}
    shift 2
    ;;
  --digest)
    digest=${2:?}
    shift 2
    ;;
  --destination)
    destination=${2:?}
    shift 2
    ;;
  *) usage ;;
  esac
done

[ -n "$url" ] && [ -n "$digest" ] && [ -n "$destination" ] || usage
case "$url" in https://*) ;; *)
  printf 'image URL must use HTTPS\n' >&2
  exit 65
  ;;
esac
case "$destination" in /*) ;; *)
  printf 'image destination must be absolute\n' >&2
  exit 65
  ;;
esac

algorithm=${digest%%:*}
expected=${digest#*:}
[ "$algorithm:$expected" = "$digest" ] || {
  printf 'image digest must be ALGORITHM:HEX\n' >&2
  exit 65
}
case "$algorithm" in
md5)
  checker=md5sum
  expression='^[0-9a-f]{32}$'
  ;;
sha256)
  checker=sha256sum
  expression='^[0-9a-f]{64}$'
  ;;
sha512)
  checker=sha512sum
  expression='^[0-9a-f]{128}$'
  ;;
*)
  printf 'unsupported image digest algorithm: %s\n' "$algorithm" >&2
  exit 65
  ;;
esac
[[ "$expected" =~ $expression ]] || {
  printf 'invalid %s digest\n' "$algorithm" >&2
  exit 65
}

for command_name in curl flock "$checker" install mkdir mv rm; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$command_name" >&2
    exit 69
  }
done

cache_dir=$(dirname "$destination")
mkdir -p "$cache_dir"
chmod 755 "$cache_dir"
lock_file="${destination}.lock"
exec 9>"$lock_file"
flock -x 9

matches_expected() {
  [ -f "$1" ] && [ "$($checker "$1" | awk '{print $1}')" = "$expected" ]
}

if matches_expected "$destination"; then
  printf 'verified image cache hit: %s\n' "$destination"
  exit 0
fi

temporary=$(mktemp "${destination}.partial.XXXXXX")
cleanup() { rm -f -- "$temporary"; }
trap cleanup EXIT
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
  --retry 4 --retry-all-errors --retry-delay 2 --output "$temporary" "$url"
matches_expected "$temporary" || {
  printf 'downloaded image digest mismatch for %s\n' "$url" >&2
  exit 65
}
chmod 644 "$temporary"
mv -f -- "$temporary" "$destination"
trap - EXIT
printf 'verified image cache populated: %s\n' "$destination"
