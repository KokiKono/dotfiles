#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/skills.sh"
LOCK="install/macos/skills-lock.json"

@test "skills.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "skills.sh: sourcing defines install_skills / read_lock / main" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; declare -F install_skills read_lock main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"install_skills"* ]]
    [[ "$output" == *"read_lock"* ]]
    [[ "$output" == *"main"* ]]
}

@test "skills.sh: skips safely when npx is absent (empty PATH)" {
    run env -i HOME="${HOME}" bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"スキップ"* ]]
}

@test "skills.sh: lock file is valid json with a skills map" {
    [ -f "${REPO_ROOT}/${LOCK}" ]
    run python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['skills']" "${REPO_ROOT}/${LOCK}"
    [ "$status" -eq 0 ]
}

@test "skills.sh: every lock entry has a source to restore from" {
    # source が無いエントリは復元できないので lock に混ざっていないこと
    run python3 -c "
import json,sys
d = json.load(open(sys.argv[1]))
bad = [n for n, m in d['skills'].items() if not m.get('source')]
assert not bad, bad
" "${REPO_ROOT}/${LOCK}"
    [ "$status" -eq 0 ]
}

@test "skills.sh: read_lock emits name and source per skill" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; read_lock '${REPO_ROOT}/${LOCK}'"
    [ "$status" -eq 0 ]
    # lock の件数と出力行数が一致すること
    count=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['skills']))" "${REPO_ROOT}/${LOCK}")
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq "$count" ]
    [[ "$output" == *"humanizer-ja"* ]]
}

@test "skills.sh: is chained from the chezmoi install script" {
    grep -q 'macos/skills.sh' "${REPO_ROOT}/home/.chezmoiscripts/run_onchange_install.sh.tmpl"
}

@test "skills.sh: external skill bodies are not vendored into the source tree" {
    # lock で管理する方針なので SKILL.md 本体を home/ に持たないこと
    [ ! -d "${REPO_ROOT}/home/dot_agents" ]
    run bash -c "ls '${REPO_ROOT}/home/dot_claude/skills' | grep '^symlink_'"
    [ "$status" -ne 0 ]
}

@test "skills.sh: reports entries that did not land, without aborting" {
    # npx をスタブ化（何もせず成功する）。CLI が終了コード 0 で取りこぼしても
    # 実体を見て警告し、他のエントリは止めないこと。
    BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${BIN}" "${BATS_TEST_TMPDIR}/dest"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/npx"
    chmod +x "${BIN}/npx"
    run env PATH="${BIN}:${PATH}" SKILLS_DEST="${BATS_TEST_TMPDIR}/dest" \
        bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"未導入"* ]]
    [[ "$output" == *"humanizer-ja"* ]]
}

@test "skills.sh: skips skills already present in the destination" {
    BIN="${BATS_TEST_TMPDIR}/bin2"
    DEST="${BATS_TEST_TMPDIR}/dest2"
    mkdir -p "${BIN}" "${DEST}"
    # npx が呼ばれたら失敗させる = 既存分は CLI を叩かないことの確認
    printf '#!/usr/bin/env bash\necho "npx should not run"\nexit 1\n' > "${BIN}/npx"
    chmod +x "${BIN}/npx"
    while IFS=$'\t' read -r name _; do
        mkdir -p "${DEST}/${name}"
    done < <(bash -c "source '${REPO_ROOT}/${SCRIPT}'; read_lock '${REPO_ROOT}/${LOCK}'")
    run env PATH="${BIN}:${PATH}" SKILLS_DEST="${DEST}" bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" != *"npx should not run"* ]]
    [[ "$output" != *"未導入"* ]]
}
