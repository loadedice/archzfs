#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || exit 1
[[ ${CANDIDATE_RUN_ID:-} =~ ^[0-9]+$ ]]
case ${KERNEL_PACKAGE:-} in linux|linux-lts) ;; *) exit 1 ;; esac

source_sha=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$CANDIDATE_RUN_ID" --jq .head_sha)
[[ $source_sha =~ ^[a-f0-9]{40}$ ]]
# Harness changes may reuse packages; changes to build inputs require a fresh
# build. Fetch only the source commit, without persisting any credentials.
git fetch --no-tags --depth=1 "https://github.com/$GITHUB_REPOSITORY.git" "$source_sha"
git diff --exit-code "$source_sha" HEAD -- \
    conf.sh build.sh lib.sh src build-container .gitmodules ci/runtime/build-candidate.sh

artifact=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$CANDIDATE_RUN_ID/artifacts" \
    --jq "[.artifacts[] | select(.expired == false and (.name | startswith(\"arch-runtime-$KERNEL_PACKAGE-\")))] | max_by(.id) | .name")
[[ $artifact == "arch-runtime-$KERNEL_PACKAGE-"* ]]
download=$(mktemp -d "$RUNNER_TEMP/archzfs-candidate.XXXXXXXX")
gh run download "$CANDIDATE_RUN_ID" --repo "$GITHUB_REPOSITORY" --name "$artifact" --dir "$download"
cp -a "$download/runtime-candidate" ./runtime-candidate
(
    cd runtime-candidate
    sha256sum --check SHA256SUMS
    grep -Fx "source=$source_sha" metadata/build.txt
    grep -Fx "repository=$GITHUB_REPOSITORY" metadata/build.txt
    grep -Fx "run=$CANDIDATE_RUN_ID" metadata/build.txt
    grep -Fx "kernel=$KERNEL_PACKAGE" metadata/build.txt
    for name in zfs-utils zfs-tests "zfs-$KERNEL_PACKAGE"; do
        test -s "metadata/$name.PKGINFO"
    done
)
mkdir -p runtime-results
printf 'Candidate packages: https://github.com/%s/actions/runs/%s\nBuild SHA: %s\nHarness SHA: %s\nArtifact: %s\n' \
    "$GITHUB_REPOSITORY" "$CANDIDATE_RUN_ID" "$source_sha" "$GITHUB_SHA" "$artifact" \
    | tee runtime-results/candidate-origin.txt >> "$GITHUB_STEP_SUMMARY"
