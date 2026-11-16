#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE_TAG:?IMAGE_TAG is required}"
: "${MANIFESTS_REPO:?MANIFESTS_REPO is required}"
: "${MANIFESTS_BRANCH:?MANIFESTS_BRANCH is required}"
: "${MANIFESTS_APP_PATH:?MANIFESTS_APP_PATH is required}"
: "${APPLICATION_NAME:?APPLICATION_NAME is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

WORKDIR="/tmp/chargersystem-chatwoot-manifests"
ASKPASS_FILE="/tmp/chargersystem-chatwoot-git-askpass.sh"

cleanup() {
  rm -rf "${WORKDIR}"
  rm -f "${ASKPASS_FILE}"
}
trap cleanup EXIT

echo "Updating ${MANIFESTS_APP_PATH}/values.yaml on ${MANIFESTS_BRANCH} to ${IMAGE_TAG}"

rm -rf "${WORKDIR}"

cat > "${ASKPASS_FILE}" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) echo "x-access-token" ;;
  *Password*) echo "${GITHUB_TOKEN}" ;;
  *) echo "" ;;
esac
EOF

chmod 700 "${ASKPASS_FILE}"

GIT_ASKPASS="${ASKPASS_FILE}" \
GITHUB_TOKEN="${GITHUB_TOKEN}" \
git clone --branch "${MANIFESTS_BRANCH}" "${MANIFESTS_REPO}" "${WORKDIR}"

cd "${WORKDIR}"

python3 - <<'PY'
from pathlib import Path
import os

values_path = Path(os.environ["MANIFESTS_APP_PATH"]) / "values.yaml"
image_tag = os.environ["IMAGE_TAG"]

if not values_path.exists():
    raise SystemExit(f"values.yaml not found: {values_path}")

lines = values_path.read_text().splitlines()
output = []
in_image_block = False
changed = False

for line in lines:
    stripped = line.strip()

    if line.startswith("image:"):
        in_image_block = True
        output.append(line)
        continue

    if in_image_block and stripped.startswith("tag:"):
        indent = line[: len(line) - len(line.lstrip())]
        output.append(f'{indent}tag: "{image_tag}"')
        changed = True
        in_image_block = False
        continue

    if in_image_block and line and not line.startswith(" "):
        in_image_block = False

    output.append(line)

if not changed:
    raise SystemExit(f"Could not find image.tag in {values_path}")

values_path.write_text("\n".join(output) + "\n")
PY

git config user.email "ci-bot@chargersystem.com"
git config user.name "chargersystem-ci-bot"

git diff -- "${MANIFESTS_APP_PATH}/values.yaml"

if git diff --quiet -- "${MANIFESTS_APP_PATH}/values.yaml"; then
  echo "No manifest changes detected"
  exit 0
fi

git add "${MANIFESTS_APP_PATH}/values.yaml"
git commit -m "deploy(${APPLICATION_NAME}): ${IMAGE_TAG}"
GIT_ASKPASS="${ASKPASS_FILE}" \
GITHUB_TOKEN="${GITHUB_TOKEN}" \
git push origin "${MANIFESTS_BRANCH}"
