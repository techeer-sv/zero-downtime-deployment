# 블루 그린 배포 뭐가 필요할까?

1. 서버 여러개 (일단 replica 3개씩 x 2)

# 어떻게 업데이트 될까?
1. 버젼 1.0.0 일단 돌아가고 있음 (블루)
2. 버젼 1.0.1로 올려야됨 (그린)
3. 그러면 일단 그린을 3개 실행 한다 (v1.0.1)
4. 그린을 검사 한다. 근데 어떻게?
    - health check?
    - 로그 분석?
    - 메트릭 분석?
5. 그린으로 요청들을 돌린다.
6. 그린 요청들이 멀쩡한거 같으면 블루를 내린다
7. 연결 끊겼는지/연결 됐는지 리버스 프록시에서 확인!

# 배포 스크립트 작성
1. 배포 스크립트를 실행할때 실행할 버젼도 같이 argument로 보낸다
    - 예시: bash deploy.sh v1.0.0
2. 현재 돌아가고있는게 블루인지 그린인지 확인한다 (도커 사용하면 됨)
    - 둘다 없을경우 블루로 배포
    - 블루가 돌아가고 있으면 그린으로 배포 (deploy-green.sh)
    - 그린이 돌아가고 있으면 블루로 배포 (deploy-blue.sh)
3. 배포 이후 헬스체크를 한다 (도커 컴포즈 파일에 있는 헬스체그면 충분 할듯)
    - 이걸 혹시 모르니 bake 한다 (x초)
4. 멀쩡한거 같으면 traefik dynamic 디렉토리에 있는 bg-routers.yaml파일을 수정한다
    - 이미 우리가 원하는 시나리오가 4가지 다 templates폴더 안에 존재한다
    - 이미 블루가 존재하고 그린을 배포한다고 가정하에 해보자 (즉 bg-routers.yaml은 green-only.yaml과 같아야한다)
    - 그린을 배포하는 경우에는 일단 `cat green-deployed.yaml > bg-routers.yaml` 을 하면 된다
        - 이 경우에는 traefik 라우터에 그린을 등록은 하지만 아직 traffic 포워딩은 하지 않는 경우다
        - 이 상태에서 최소 10초 정도 bake
    - 라우터 등록이 잘 된거 같으면 `cat blue-deployed.yaml > bg-routers.yaml` 을 하면 된다
        - 이 경우에는 traffic 포워딩을 블루에서 그린으로 옮긴거다
        - 이 상태에서 최소 10초 정도 bake
    - 그린이 요청을 잘 처리하는거 같으면 블루를 라우터에서 없애면 된다. `cat green-only.yaml > bg-routers.yaml`을 실행하면 된다
5. 이제 라우터를 스위칭 했으니 안사용하는 블루 컨테이너들을 내리면 된다 (down-blue.sh)
6. 나중에 블루를 v1.0.1으로 배포할때는 step 4를 사실상 반대로 하면 된다

---

# deploy.sh 구현 요약

> `scripts/deploy.sh` 에 구현된 내용이다.

## 사용법

```bash
bash deploy.sh <이미지_태그>

# 예시
bash deploy.sh v1.0.1
```

## 전체 흐름

```
[인자 확인] → [환경 감지] → [신규 환경 기동] → [헬스체크] → [라우터 전환 3단계] → [구환경 종료]
```

## 환경 감지 → 배포 방향 결정

`docker compose ps --status running` 으로 실행 중인 컨테이너 수를 확인해서 배포 방향을 자동으로 결정한다.

| 현재 상태 | 배포 대상 | 비고 |
|-----------|-----------|------|
| 둘 다 없음 | 블루 | 초기 배포 |
| 블루만 실행 중 | 그린 | 일반 배포 |
| 그린만 실행 중 | 블루 | 일반 배포 |
| 둘 다 실행 중 | ❌ 오류 종료 | 이전 배포가 덜 끝난 상태 |

## 헬스체크

- docker compose에 정의된 healthcheck (`GET /health`) 결과를 사용한다
- `docker compose ps` 출력에서 `(healthy)` 상태 컨테이너 수를 5초 간격으로 폴링
- replica 3개가 모두 healthy 상태가 될 때까지 최대 90초 대기
- 타임아웃 시 현재 컨테이너 상태를 출력하고 스크립트를 종료한다

## Traefik 라우터 전환 3단계

`templates/` 폴더의 yaml 파일을 `dynamic/bg-routers.yaml`에 덮어쓰는 방식으로 전환한다.  
각 단계마다 Traefik이 변경을 감지해 반영할 수 있도록 **10초 bake** 대기한다.

### 템플릿 파일 의미

| 파일 | 블루 가중치 | 그린 가중치 | 의미 |
|------|------------|------------|------|
| `blue-only.yaml` | 100% | — | 블루만 라우터에 등록 |
| `green-only.yaml` | — | 100% | 그린만 라우터에 등록 |
| `blue-deployed.yaml` | 0% | 100% | 블루가 방금 배포됨 (라우터 등록, 트래픽은 아직 그린) |
| `green-deployed.yaml` | 100% | 0% | 그린이 방금 배포됨 (라우터 등록, 트래픽은 아직 블루) |

> **네이밍 규칙:** `{X}-deployed.yaml`은 X가 방금 라우터에 **등록**된 상태를 나타낸다.  
> X의 가중치는 0%이고, 트래픽은 아직 반대편 환경이 받고 있다.

### 그린 배포 시 (블루 → 그린)

| 단계 | 적용 템플릿 | 블루 | 그린 | 설명 |
|------|------------|------|------|------|
| 1단계 | `green-deployed.yaml` | 100% | 0% | 그린을 라우터에 등록, 트래픽은 블루 유지 |
| 2단계 | `blue-deployed.yaml` | 0% | 100% | 트래픽을 블루 → 그린으로 전환 |
| 3단계 | `green-only.yaml` | — | 100% | 블루를 라우터에서 제거 |

### 블루 배포 시 (그린 → 블루)

| 단계 | 적용 템플릿 | 블루 | 그린 | 설명 |
|------|------------|------|------|------|
| 1단계 | `blue-deployed.yaml` | 0% | 100% | 블루를 라우터에 등록, 트래픽은 그린 유지 |
| 2단계 | `green-deployed.yaml` | 100% | 0% | 트래픽을 그린 → 블루로 전환 |
| 3단계 | `blue-only.yaml` | 100% | — | 그린을 라우터에서 제거 |

## 파일 구조

```
plans/bluegreen/
├── blue.yaml                  # 블루 docker compose 파일 (replica 3, port 8080-8082)
├── green.yaml                 # 그린 docker compose 파일 (replica 3, port 8083-8085)
├── dynamic/
│   └── bg-routers.yaml        # Traefik이 감시하는 동적 라우터 설정 (배포 중 교체됨)
├── templates/
│   ├── blue-only.yaml         # 블루만 라우터에 등록
│   ├── green-only.yaml        # 그린만 라우터에 등록
│   ├── blue-deployed.yaml     # 블루 등록됨 (트래픽은 그린)
│   └── green-deployed.yaml    # 그린 등록됨 (트래픽은 블루)
└── scripts/
    ├── deploy.sh              # 메인 배포 스크립트 (이 파일)
    ├── deploy-blue.sh         # 블루 컨테이너 3개 기동
    ├── deploy-green.sh        # 그린 컨테이너 3개 기동
    ├── down-blue.sh           # 블루 컨테이너 종료
    └── down-green.sh          # 그린 컨테이너 종료
```
