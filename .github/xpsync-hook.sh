#!/usr/bin/env bash
# xpsync hook — bump CMakeLists.txt to the newest upstream Kitware/CMake release.
# Invoked by the xpsync "hook" job on the `xpsync` branch. Make commits for any
# work; the workflow pushes the branch and the sync opens a PR when the branch
# ends up ahead of the default branch. Must stay cheap and idempotent — it runs
# on every xpsync trigger (schedule, push to xpsync, workflow_dispatch).
# Keep it token-free: unauthenticated GitHub API is fine for a daily check.
set -euo pipefail
UPSTREAM=Kitware/CMake

cur_base=$(awk '/^project\(cmake-pkg VERSION/ {print $3; exit}' CMakeLists.txt)
cur_rc=$(awk '/^set\(RC/ {if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2); exit}' CMakeLists.txt)
[[ -n "${cur_base}" ]] || { echo "::error::could not parse project VERSION"; exit 1; }
cur="${cur_base}${cur_rc}"
echo "current: ${cur}"

cat > /tmp/vkey.py <<'PY'
import re, sys
def key(t):
    m = re.match(r'v?(\d+)\.(\d+)\.(\d+)(?:-rc(\d+))?$', t.strip())
    if not m: return (-1, 0, 0, 0, 0)
    a, b, c, rc = m.groups()
    return (int(a), int(b), int(c), 0 if rc else 1, int(rc or 0))
if sys.argv[1] == 'max':
    print(max((l.strip() for l in sys.stdin if l.strip()), key=key))
else:  # 'newer' NEW OLD: exit 0 if NEW > OLD
    sys.exit(0 if key(sys.argv[2]) > key(sys.argv[3]) else 1)
PY

latest=$(curl -fsSL "https://api.github.com/repos/${UPSTREAM}/releases" \
  | python3 -c "import json,sys; print('\n'.join(r['tag_name'] for r in json.load(sys.stdin)))" \
  | python3 /tmp/vkey.py max)
echo "upstream latest: ${latest}"
python3 /tmp/vkey.py newer "${latest}" "v${cur}" || { echo "already up to date"; exit 0; }

new="${latest#v}"         # e.g. 4.6.0 or 4.6.0-rc1
base="${new%%-rc*}"       # e.g. 4.6.0
rc="${new#"${base}"}"     # e.g. -rc1 or empty

if git log -n 30 --format=%s | grep -qx "cmake ${new} repackage .tar.gz as .rpm"; then
  echo "bump to ${new} already committed on this branch"; exit 0
fi

sums=$(curl -fsSL "https://github.com/${UPSTREAM}/releases/download/${latest}/cmake-${new}-SHA-256.txt")
sha_aarch64=$(awk -v f="cmake-${new}-linux-aarch64.tar.gz" '$2 == f {print $1}' <<<"${sums}")
sha_x86_64=$(awk -v f="cmake-${new}-linux-x86_64.tar.gz" '$2 == f {print $1}' <<<"${sums}")
[[ "${sha_aarch64}" =~ ^[0-9a-f]{64}$ && "${sha_x86_64}" =~ ^[0-9a-f]{64}$ ]] || {
  echo "::error::could not extract SHA-256 sums for ${new}"; exit 1; }

sed -i -E \
  -e "s|^project.cmake-pkg VERSION [0-9.]+|project(cmake-pkg VERSION ${base}|" \
  -e "s|^set.RC \".*\".|set(RC \"${rc}\")|" \
  -e "s|^# https://github.com/Kitware/CMake/releases/tag/.*|# https://github.com/Kitware/CMake/releases/tag/v${new}|" \
  -e "s|^# https://github.com/Kitware/CMake/releases/download/.*linux-aarch64.*|# https://github.com/Kitware/CMake/releases/download/v${new}/cmake-${new}-linux-aarch64.tar.gz|" \
  -e "s|^# https://github.com/Kitware/CMake/releases/download/.*linux-x86_64.*|# https://github.com/Kitware/CMake/releases/download/v${new}/cmake-${new}-linux-x86_64.tar.gz|" \
  -e "s|^set.sha_aarch64 [0-9a-f]+.|set(sha_aarch64 ${sha_aarch64})|" \
  -e "s|^set.sha_x86_64 [0-9a-f]+.|set(sha_x86_64 ${sha_x86_64})|" \
  CMakeLists.txt
git diff --check
git diff --quiet && { echo "::error::no changes produced"; exit 1; }

if [[ -n "${rc}" ]]; then xptag="xpv${new}"; else xptag="xpv${new}.1"; fi
printf '{\n  "message": "xpro version %s tag",\n  "tag": "%s"\n}\n' "${xptag#xpv}" "${xptag}" > .github/release-tag.json

git add CMakeLists.txt .github/release-tag.json
git commit -m "cmake ${new} repackage .tar.gz as .rpm"
