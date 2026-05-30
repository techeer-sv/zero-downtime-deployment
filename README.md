# zero-downtime-deployment

무중단 배포(Zero Downtime Deployment) 전략을 직접 구현하고 실험해보는 핸즈온 레포지토리다.
블루-그린, 카나리, 롤링, 섀도우 네 가지 배포 방식을 각각 Docker + Traefik으로 구현한다.

배포 전략의 이론적 배경은 [`docs/TYPES.md`](docs/TYPES.md)를 참고한다.

---

## 디렉토리 구조

```
zero-downtime-deployment/
├── app/                    # 실험용 Go HTTP 서버 (배포 대상 앱)
├── scripts/                # 공용 스크립트 (이미지 빌드)
├── plans/
│   ├── bluegreen/          # 블루-그린 배포
│   ├── canary/             # 카나리 배포
│   ├── rolling/            # 롤링 배포
│   └── shadow/             # 섀도우 배포
├── test/                   # k6 부하 테스트
└── docs/                   # 배포 전략 이론 문서
```

---

## 실험용 앱 (`app/`)

배포 대상이 되는 단순한 Go HTTP 서버다.

| 엔드포인트 | 응답 | 설명 |
|-----------|------|------|
| `GET /` | `version - <버전>` | 현재 실행 중인 버전을 반환 |
| `GET /health` | `ok` | 헬스체크용 |

버전은 이미지 빌드 시 `APP_VERSION` 빌드 인자로 주입된다.

---

## 빠른 시작

### 1. 앱 이미지 빌드

배포 실험을 하기 전에 먼저 구버전과 신버전 이미지를 빌드해야 한다.

```bash
bash scripts/build.sh v1.0.0   # 구버전 (stable)
bash scripts/build.sh v1.0.1   # 신버전 (new)
```

빌드된 이미지: `zero-downtime-app:v1.0.0`, `zero-downtime-app:v1.0.1`

### 2. 원하는 배포 방식 선택 후 실행

```bash
# 블루-그린
cd plans/bluegreen
docker compose up -d           # Traefik 실행
bash scripts/deploy.sh v1.0.1  # 배포

# 카나리
cd plans/canary
docker compose up -d
bash scripts/deploy.sh v1.0.1

# 롤링
cd plans/rolling
docker compose up -d
bash scripts/deploy.sh v1.0.1 start-first
```

---

## 배포 방식별 요약

### 블루-그린 (`plans/bluegreen/`)

두 개의 동일한 환경(블루/그린)을 운영하며 트래픽을 한 번에 전환한다.

```
[블루 100%] → 그린 기동 → 헬스체크 → [그린 100%] → 블루 종료
```

- **장점:** 즉각적인 전환, 빠른 롤백
- **단점:** 인프라 비용 2배
- 자세한 내용: [`plans/bluegreen/README.md`](plans/bluegreen/README.md)

### 카나리 (`plans/canary/`)

트래픽을 단계적으로 늘려가며 신버전의 안정성을 검증한다.

```
[구버전 100%] → [5%] → [20%] → [50%] → [100%] → 구버전 종료
                 ↓       ↓        ↓        ↓
              헬스체크  헬스체크  헬스체크  헬스체크 (실패 시 자동 롤백)
```

- **장점:** 문제 발생 시 소수 사용자만 영향, 실 트래픽 검증
- **단점:** 배포 시간이 길고, 두 버전이 동시에 서비스됨
- 자세한 내용: [`plans/canary/README.md`](plans/canary/README.md)

### 롤링 (`plans/rolling/`)

컨테이너를 하나씩 순차적으로 신버전으로 교체한다. `stop-first`와 `start-first` 두 가지 모드를 지원한다.

```
[구 구 구] → [구 구 신] → [구 신 신] → [신 신 신]
```

- **장점:** 추가 인프라 없이 교체 가능
- **단점:** 배포 중 두 버전 공존, stop-first는 순간 용량 감소
- 자세한 내용: [`plans/rolling/README.md`](plans/rolling/README.md)

### 섀도우 (`plans/shadow/`)

실제 트래픽을 신버전에 미러링하여 사용자에게 영향 없이 신버전을 검증한다.

```
사용자 요청 → [구버전] → 응답 반환
                  ↓
             [신버전] (미러, 응답 무시)
```

- **장점:** 실 트래픽으로 신버전 검증, 사용자 영향 없음
- **단점:** 신버전의 부작용(DB 쓰기 등)이 발생할 수 있어 주의 필요
- 자세한 내용: [`plans/shadow/README.md`](plans/shadow/README.md)

---

## 공통 인프라

모든 배포 방식은 다음 공통 인프라를 사용한다.

| 컴포넌트 | 역할 |
|---------|------|
| **Traefik v3** | 리버스 프록시 + 동적 라우팅 |
| **Docker Compose** | 컨테이너 오케스트레이션 |
| **dynamic/*.yaml** | Traefik이 감시하는 라우터 설정 (파일 교체로 hot-reload) |

### Traefik 대시보드

각 `docker-compose.yaml`을 실행하면 Traefik 대시보드에 접근할 수 있다.

```
http://localhost:8090
```

---

## 부하 테스트 (`test/`)

k6를 사용한 부하 테스트로 배포 중 요청이 끊기지 않는지 검증할 수 있다.
자세한 내용: [`test/README.md`](test/README.md)
