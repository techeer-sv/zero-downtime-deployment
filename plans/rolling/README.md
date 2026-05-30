# 롤링 배포 (Rolling Deployment)

롤링 배포는 구버전 컨테이너를 한 번에 교체하지 않고 **하나씩 순차적으로** 신버전으로 교체하는 방식이다.
교체 순서에 따라 **stop-first** 와 **start-first** 두 가지 모드를 지원한다.

## 사용법

```bash
bash scripts/deploy.sh <이미지_태그> [방식]

# 예시
bash scripts/deploy.sh v1.0.1 start-first   # start-first 방식
bash scripts/deploy.sh v1.0.1 stop-first    # stop-first 방식
bash scripts/deploy.sh v1.0.1              # 방식 생략 시 start-first 기본 적용
```

## 전체 흐름

```
[인자 확인] → [환경 감지] → [모드에 따라 순차 교체 × 3회] → [신버전 3개 완료]
```

---

## 환경 감지 → 배포 방향 결정

`docker ps` 로 실행 중인 `app-rolling` 컨테이너를 확인해서 초기 배포 여부를 판단한다.

| 현재 상태 | 동작 | 비고 |
|-----------|------|------|
| 컨테이너 없음 | `deploy-rolling.sh`로 신버전 3개 한번에 기동 | 초기 배포 |
| 구버전 컨테이너 실행 중 | 선택한 모드로 순차 교체 시작 | 일반 배포 |

---

## 두 가지 모드 비교

| 항목 | stop-first | start-first |
|------|-----------|-------------|
| 교체 순서 | 구버전 제거 → 신버전 추가 | 신버전 추가 → 구버전 제거 |
| 교체 중 최소 replica | **2개** (순간 감소) | **3개** (항상 유지) |
| 교체 중 최대 replica | 3개 | **4개** (순간 증가) |
| 헬스체크 실패 시 | 구버전+신버전 혼재 상태로 중단 | 신버전 제거 후 이전 상태 복구 |
| 적합한 상황 | 리소스가 제한적일 때 | 무중단 보장이 중요할 때 |

---

## stop-first 흐름

> 구버전을 먼저 제거한 뒤 신버전을 추가한다. 교체 중 잠시 replica가 2개로 줄어드는 시점이 생긴다.

```
시작: [구 구 구]

1회차:  remove-old → [구 구]
        deploy-extra → [구 구 신]  ← 헬스체크 (실패 시 중단)

2회차:  remove-old → [구 신]
        deploy-extra → [구 신 신]  ← 헬스체크 (실패 시 중단)

3회차:  remove-old → [신 신]
        deploy-extra → [신 신 신]  ← 헬스체크 (실패 시 중단)

완료: [신 신 신]
```

### 단계별 상태 (stop-first)

| 회차 | 단계 | 구버전 | 신버전 | 총 replica |
|------|------|--------|--------|------------|
| 시작 | — | 3 | 0 | 3 |
| 1회차 | remove-old | 2 | 0 | **2** |
| 1회차 | deploy-extra + 헬스체크 | 2 | 1 | 3 |
| 2회차 | remove-old | 1 | 1 | **2** |
| 2회차 | deploy-extra + 헬스체크 | 1 | 2 | 3 |
| 3회차 | remove-old | 0 | 2 | **2** |
| 3회차 | deploy-extra + 헬스체크 | 0 | 3 | 3 |

---

## start-first 흐름

> 신버전을 먼저 추가하고 헬스체크 통과 후 구버전을 제거한다. 항상 최소 3개의 replica가 유지된다.

```
시작: [구 구 구]

1회차:  deploy-extra → [구 구 구 신]  ← 헬스체크
        실패 시: 신버전 제거 → [구 구 구] 로 복귀
        성공 시: remove-old → [구 구 신]

2회차:  deploy-extra → [구 구 신 신]  ← 헬스체크
        실패 시: 신버전 제거 → [구 구 신] 유지
        성공 시: remove-old → [구 신 신]

3회차:  deploy-extra → [구 신 신 신]  ← 헬스체크
        실패 시: 신버전 제거 → [구 신 신] 유지
        성공 시: remove-old → [신 신 신]

완료: [신 신 신]
```

### 단계별 상태 (start-first)

| 회차 | 단계 | 구버전 | 신버전 | 총 replica |
|------|------|--------|--------|------------|
| 시작 | — | 3 | 0 | 3 |
| 1회차 | deploy-extra | 3 | 1 | **4** |
| 1회차 | 헬스체크 통과 후 remove-old | 2 | 1 | 3 |
| 2회차 | deploy-extra | 2 | 2 | **4** |
| 2회차 | 헬스체크 통과 후 remove-old | 1 | 2 | 3 |
| 3회차 | deploy-extra | 1 | 3 | **4** |
| 3회차 | 헬스체크 통과 후 remove-old | 0 | 3 | 3 |

---

## 헬스체크

- docker compose에 정의된 healthcheck (`GET /health`) 결과를 사용한다
- `docker ps` 출력에서 신규 추가된 컨테이너가 `(healthy)` 상태가 될 때까지 폴링
- 헬스체크 실패 시 동작은 모드에 따라 다르다

| 모드 | 헬스체크 실패 시 동작 |
|------|--------------------|
| stop-first | 배포 즉시 중단. 구버전+신버전 혼재 상태 유지 |
| start-first | 신규 추가한 컨테이너 제거 후 중단. 이전 상태로 복귀 |

---

## 스크립트

| 스크립트 | 인자 | 역할 |
|----------|------|------|
| `deploy.sh` | `<tag> [방식]` | 메인 배포 스크립트. 환경 감지 후 모드에 따라 순차 교체 실행 |
| `deploy-rolling.sh` | `<tag>` | 신버전 3개 한번에 기동 (초기 배포용) |
| `deploy-extra.sh` | `<tag> <parallel>` | 현재 replica에 `<parallel>`개 추가 (`--no-recreate`로 기존 컨테이너 유지) |
| `remove-old.sh` | `<container>` | 특정 컨테이너를 stop 후 rm |

### deploy-extra.sh 동작 방식

```bash
# PARALLEL=0이면 총 3+0=3, PARALLEL=1이면 총 3+1=4
REPLICA=$((PARALLEL + 3))
docker compose -f rolling.yaml up -d --scale app-rolling=$REPLICA --no-recreate
```

`--no-recreate` 옵션 덕분에 기존에 실행 중인 구버전 컨테이너는 건드리지 않고, 새 신버전 컨테이너만 추가된다.

---

## 파일 구조

```
plans/rolling/
├── rolling.yaml               # app-rolling docker compose 파일 (port 8080-8083)
├── docker-compose.yaml        # Traefik + 공통 네트워크 설정
├── dynamic/
│   └── router.yaml            # Traefik이 감시하는 동적 라우터 설정
└── scripts/
    ├── deploy.sh              # 메인 배포 스크립트 (환경 감지 + 모드 분기)
    ├── deploy-rolling.sh      # 신버전 3개 한번에 기동 (초기 배포)
    ├── deploy-extra.sh        # 현재 replica에 N개 추가
    └── remove-old.sh          # 특정 구버전 컨테이너 제거
```
