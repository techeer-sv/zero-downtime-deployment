# scripts/

배포 실험 전에 앱 이미지를 빌드하는 공용 스크립트 모음이다.

## build.sh

`app/` 디렉토리의 Go 서버를 Docker 이미지로 빌드한다.

```bash
bash scripts/build.sh <버전>

# 예시
bash scripts/build.sh v1.0.0   # 구버전 이미지
bash scripts/build.sh v1.0.1   # 신버전 이미지
```

빌드 결과: `zero-downtime-app:<버전>` 이미지가 로컬 Docker에 저장된다.

| 빌드 인자 | 설명 |
|----------|------|
| `APP_VERSION` | 앱이 `GET /` 응답에 반환하는 버전 문자열 |

각 배포 실험을 시작하기 전에 구버전과 신버전 이미지를 미리 빌드해둬야 한다.

```bash
bash scripts/build.sh v1.0.0
bash scripts/build.sh v1.0.1
```
