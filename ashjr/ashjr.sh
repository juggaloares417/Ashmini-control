#!/usr/bin/env bash
set -euo pipefail
CTRL="$PWD"
APP="$CTRL/app"
: "${REPO:?}"; : "${RUN_ID:?}"; : "${GH_TOKEN:?}"
LOG="$CTRL/ashjr/run.log"

[ -s "$LOG" ] || gh run view -R "$REPO" "$RUN_ID" --log > "$LOG"

branch="ashjr/fix-${RUN_ID}"
fixed=""

# 1) AndroidX flags missing
if grep -q 'contains AndroidX dependencies, but the `android.useAndroidX` property is not enabled' "$LOG"; then
  git -C "$APP" checkout -B "$branch" || git -C "$APP" checkout "$branch"
  touch "$APP/gradle.properties"
  grep -q '^android.useAndroidX=' "$APP/gradle.properties" || echo 'android.useAndroidX=true' >> "$APP/gradle.properties"
  grep -q '^android.enableJetifier=' "$APP/gradle.properties" || echo 'android.enableJetifier=true' >> "$APP/gradle.properties"
  git -C "$APP" add gradle.properties
  git -C "$APP" commit -m "AshJR: enable AndroidX + Jetifier (run $RUN_ID)" || true
  fixed="${fixed}androidx,"
fi

# 2) Bad Gradle distribution path (phone path)
if grep -q 'FileNotFoundException' "$LOG" && grep -q 'file:/data/data' "$LOG"; then
  git -C "$APP" checkout -B "$branch" || git -C "$APP" checkout "$branch"
  mkdir -p "$APP/gradle/wrapper"
  cat > "$APP/gradle/wrapper/gradle-wrapper.properties" <<'PROP'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.7-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
PROP
  git -C "$APP" add gradle/wrapper/gradle-wrapper.properties
  git -C "$APP" commit -m "AshJR: fix Gradle distribution URL (run $RUN_ID)" || true
  fixed="${fixed}wrapper-url,"
fi

# 3) gradlew not executable
if grep -qi 'Permission denied' "$LOG" && grep -q './gradlew' "$LOG"; then
  git -C "$APP" checkout -B "$branch" || git -C "$APP" checkout "$branch"
  chmod +x "$APP/gradlew" || true
  git -C "$APP" add gradlew || true
  git -C "$APP" commit -m "AshJR: make gradlew executable (run $RUN_ID)" || true
  fixed="${fixed}gradlew-x,"
fi

if [ -n "$fixed" ]; then
  git -C "$APP" config user.name  "AshJR Bot"
  git -C "$APP" config user.email "ashjr-bot@users.noreply.github.com"
  git -C "$APP" push -f "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" HEAD:"$branch"

  pr_url=$(GH_TOKEN="$GH_TOKEN" gh pr create -R "$REPO" --head "$branch" --base main \
    --title "AshJR: auto-fix (${fixed%?})" \
    --body "Detected patterns: ${fixed%?} on run $RUN_ID. Auto-fixes applied.")
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  mkdir -p "$CTRL/ashjr"
  echo '{"time":"'"$ts"'","repo":"'"$REPO"'","run_id":"'"$RUN_ID"'","patterns":"'"${fixed%?}"'","pr":"'"$pr_url"'"}' >> "$CTRL/ashjr/history.ndjson"
  git -C "$CTRL" add ashjr/history.ndjson && git -C "$CTRL" commit -m "AshJR: record fix for $REPO run $RUN_ID" || true
  git -C "$CTRL" push

  curl -sS -X POST -H "Accept: application/vnd.github+json" \
    -H "Authorization: token ${GH_TOKEN}" \
    "https://api.github.com/repos/${REPO}/dispatches" \
    -d '{"event_type":"build"}' >/dev/null
  echo "Fix pushed, PR opened, build re-triggered."
else
  echo "No known patterns found. See ashjr/run.log"
fi
