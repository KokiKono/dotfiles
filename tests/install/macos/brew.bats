#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/brew.sh"

@test "brew.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "brew.sh: sourcing defines functions without side effects" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; declare -F install_homebrew trust_taps brew_bundle main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"install_homebrew"* ]] || false
    [[ "$output" == *"trust_taps"* ]] || false
    [[ "$output" == *"brew_bundle"* ]] || false
    [[ "$output" == *"main"* ]] || false
}

@test "brew.sh: references the Brewfile" {
    run grep -q 'REPO_ROOT}/Brewfile' "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "brew.sh: a failed Brewfile dependency does not abort the chain" {
    # chezmoi の run_onchange は set -Eeuo pipefail の下で各スクリプトを順に呼ぶので、
    # ここが非 0 で返ると gh / skills / herdr と設定ファイルの配備まで止まる。
    STUB="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB}"
    cat > "${STUB}/brew" <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in
  bundle) echo "Installing corepack has failed!" >&2; exit 1 ;;
  help)   exit 1 ;;
esac
exit 0
STUBEOF
    chmod +x "${STUB}/brew"
    # main 経由だと load_brew_env が /opt/homebrew/bin/brew を絶対パスで PATH に戻して
    # スタブを追い越すので、brew_bundle を直接呼ぶ。
    run env PATH="${STUB}:/usr/bin:/bin" HOME="${HOME}" \
        bash -c "source '${REPO_ROOT}/${SCRIPT}'; brew_bundle"
    [ "$status" -eq 0 ]
    [[ "$output" == *"警告"* ]] || false
}

@test "brew.sh: Brewfile does not install corepack alongside the pnpm formula" {
    # corepack は /opt/homebrew/bin/pnpm にシムを張ろうとし、brew formula の pnpm と
    # EEXIST で衝突して brew bundle ごと落ちる。両方を同時に持たせない。
    if grep -q '^brew "pnpm"' "${REPO_ROOT}/Brewfile"; then
        run grep -q '^npm "corepack"' "${REPO_ROOT}/Brewfile"
        [ "$status" -ne 0 ]
    fi
}

@test "brew.sh: helix ships with the language servers it expects by name" {
    # Helix は言語ごとに決め打ちのバイナリ名でサーバーを起動する（hx --health で確認できる）。
    # formula 名がその名前と一致しているので languages.toml は要らないが、
    # 片方だけ消えると「開くが何も効かない」状態になるので対で持たせる。
    grep -q '^brew "helix"' "${REPO_ROOT}/Brewfile" || skip "helix is not in the Brewfile"
    for f in typescript-language-server vscode-langservers-extracted yaml-language-server; do
        grep -q "^brew \"${f}\"" "${REPO_ROOT}/Brewfile"
    done
}
