#!/bin/bash
# Оновлює Holos до останньої версії з GitHub: підтягує зміни, за потреби оновлює
# залежності, перезбирає й перезапускає застосунок.
set -euo pipefail

# Усе тіло — у функції: bash прочитає скрипт повністю ще до git pull,
# тож нова версія цього ж файлу не зламає виконання посередині
main() {
    cd "$(dirname "$0")/.."

    echo "Перевіряю оновлення…"
    git fetch --quiet origin

    if git merge-base --is-ancestor '@{u}' HEAD; then
        echo "✓ Нових змін немає ($(git rev-parse --short HEAD))"
        echo "  Щоб просто перезібрати й перезапустити: scripts/build.sh --install"
        return 0
    fi

    echo "Нові зміни:"
    git log --format='  %h %s' 'HEAD..@{u}'

    if ! git merge --ff-only --quiet '@{u}'; then
        echo >&2
        echo "Не вдалося оновитися автоматично: у вас є локальні зміни або коміти, яких немає на GitHub." >&2
        echo "Перегляньте їх (git status, git log), закомітьте чи сховайте (git stash) і запустіть знову." >&2
        return 1
    fi

    scripts/fetch-deps.sh
    scripts/build.sh --install
    echo "✓ Holos оновлено до $(git rev-parse --short HEAD)"
}

main "$@"; exit
