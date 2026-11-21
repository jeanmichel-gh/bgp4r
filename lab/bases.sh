#!/bin/sh
# bases.sh [--list] [NAME=VALUE...] DOCKERFILE...: the images their FROMs
# name, tagged here before a build. --list prints them and pulls nothing.
# NAME=VALUE is a --build-arg the build will pass, in place of the ARG's
# default.
#
#   lab/bases.sh Dockerfile
#   lab/bases.sh RUBY_VERSION=4.0 Dockerfile
#
# BuildKit asks Docker Hub for each base image's metadata at every build,
# unless the image is tagged on the machine. On a slow line that failed
# routescope's lab jobs with "net/http: TLS handshake timeout"
# (routescope docs/ci.md, "Base images"). Measured on routescope's CI VM:
# with the base tagged, "load metadata" takes 0.0 s and the build passes
# with Docker Hub blocked; with it in the build cache only, 1.6 to 5.3 s,
# and it fails when Hub is blocked.
#
# So a base is pulled once, tried three times 15 s apart, and kept. A tag
# kept is not refreshed: docker pull it to take a newer one. On GitHub's
# machines every job starts empty, so each is pulled, with the retries.
set -u
list=
[ "${1:-}" = --list ] && { list=1; shift; }
sets=
while [ $# -gt 0 ]; do
  case "$1" in
    *=*) sets="$sets $1"; shift ;;
    *) break ;;
  esac
done

# Each FROM's image, with the ARG values put in, leaving out the file's
# own stages and scratch.
images() {
  for f in "$@"; do
    awk -v sets="$sets" '
      BEGIN { n = split(sets, s, " "); for (j = 1; j <= n; j++) { p = index(s[j], "="); arg[substr(s[j], 1, p - 1)] = substr(s[j], p + 1) } }
      toupper($1) == "ARG" {
        p = index($2, "="); if (p > 0) { k = substr($2, 1, p - 1); if (!(k in arg)) arg[k] = substr($2, p + 1) }
      }
      toupper($1) == "FROM" {
        i = 2; while (substr($i, 1, 2) == "--") i++
        img = $i
        for (k in arg) { gsub("\\$\\{" k "\\}", arg[k], img); gsub("\\$" k, arg[k], img) }
        if (!(tolower(img) in stage) && img != "scratch") print img
        if (toupper($(i + 1)) == "AS") stage[tolower($(i + 2))] = 1
      }' "$f" || exit 1
  done | awk '!seen[$0]++'
}

pull() {
  for try in 1 2 3; do
    docker pull -q "$1" >/dev/null && return 0
    [ "$try" = 3 ] && break
    echo "bases.sh: $1 failed (try $try of 3), again in 15 s" >&2
    sleep 15
  done
  echo "bases.sh: $1 failed 3 times" >&2
  return 1
}

out="$(images "$@")" || exit 1
for img in $out; do
  if [ -n "$list" ]; then echo "$img"; continue; fi
  docker image inspect "$img" >/dev/null 2>&1 || pull "$img" || exit 1
done
