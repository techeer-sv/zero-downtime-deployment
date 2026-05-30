#!/bin/bash

# ============================================================
# 롤링 무중단 배포 메인 스크립트
#
# 사용법: bash deploy.sh <이미지_태그> [방식]
# 예시:   bash deploy.sh v1.0.1 stop-first
#         bash deploy.sh v1.0.1 start-first
#         bash deploy.sh v1.0.1            # start-first 기본값
#
# 방식:
#   stop-first  — 구버전 제거 → 신버전 추가 → 헬스체크 (capacity 감소)
#   start-first — 신버전 추가 → 헬스체크 → 구버전 제거 (capacity 유지)
# ============================================================

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "❌ 오류: 배포할 이미지 태그를 인자로 전달해야 합니다."
    echo "   사용법: bash deploy.sh <이미지_태그> [방식]"
    echo "   방식:   stop-first | start-first (기본값: start-first)"
    echo "   예시:   bash deploy.sh v1.0.1 stop-first"
    exit 1
fi

IMAGE_TAG="$1"
MODE="${2:-start-first}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$MODE" in
    stop-first)
        bash "$SCRIPT_DIR/deploy-stop-first.sh" "$IMAGE_TAG"
        ;;
    start-first)
        bash "$SCRIPT_DIR/deploy-start-first.sh" "$IMAGE_TAG"
        ;;
    *)
        echo "❌ 알 수 없는 방식: $MODE"
        echo "   지원하는 방식: stop-first | start-first"
        exit 1
        ;;
esac
