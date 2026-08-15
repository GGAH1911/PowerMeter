# PowerMeter ⚡

맥북의 **실시간 전력 흐름**을 메뉴바에서 보여주고, **배터리 충전 제한**까지 제어하는 가벼운 macOS 메뉴바 앱. AlDente 대체를 목표로 만들어졌습니다.

> A lightweight macOS menu bar app that visualizes real-time power flow (adapter → Mac → battery) and controls battery charge limits. An open AlDente alternative for Apple Silicon.

## 주요 기능

- **메뉴바 실시간 전력** — 시스템 소비 / 어댑터 공급 / 배터리 충·방전 와트 + 배터리 %
- **전력 흐름 다이어그램** — 어댑터·맥·배터리 노드 사이를 흐르는 애니메이션. 4가지 상태 자동 판별:
  - ⚡ 충전 (어댑터 → 맥 + 배터리)
  - 🔌+🔋 동시 사용 (어댑터 부족분을 배터리가 보충)
  - 🔌 어댑터 구동 (충전 보류)
  - 🔋 배터리 구동
- **배터리 건강 대시보드** — macOS와 일치하는 건강%, 설계/최대 용량, 사이클, 온도, 어댑터 사양, 에너지 사용 상위 앱
- **충전 제어** (AlDente 대체) — 충전 상한 슬라이더·프리셋, Sailing(범위 유지), 강제 방전/충전, 캘리브레이션
- **메뉴바 폭 조절** — 아이콘만 / 잔량 / 전력 / 전체 4단계로 상태바 길이 선택 (미리보기 제공)
- **설정** — 갱신 주기, 소수점 표시, 로그인 시 자동 시작

전력·건강 데이터는 **권한 없이 IOKit**(`AppleSmartBattery`)만으로 읽습니다. 충전 제어만 별도 엔진이 필요합니다.

## 요구 사항

- **Apple Silicon (M1~M4)** — 전력 흐름 데이터가 Apple Silicon 전용 IOKit 키 기반
- **macOS 13 (Ventura) 이상**
- 충전 제어 기능: [`battery` CLI](https://github.com/actuallymentor/battery) (선택)

## 설치

### Homebrew (권장)
```bash
brew install --cask ggah1911/tap/powermeter
```
ad-hoc 서명만 된 미공증 앱이라 cask가 설치 후 격리 속성을 자동 해제합니다.

### 미리 빌드된 앱 (Releases)
[Releases](https://github.com/GGAH1911/PowerMeter/releases)에서 zip을 받아:
```bash
unzip PowerMeter-v1.1-arm64.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/PowerMeter.app   # 미공증 앱 격리 해제
open /Applications/PowerMeter.app
```

### 직접 빌드
```bash
cd PowerMeter
./build.sh
cp -R PowerMeter.app /Applications/
open /Applications/PowerMeter.app
```

## 충전 제어 활성화 (선택)

충전 상한·방전·캘리브레이션은 검증된 오픈소스 [`battery`](https://github.com/actuallymentor/battery) 엔진에 위임합니다 (직접 SMC를 건드리지 않음).

```bash
curl -s https://raw.githubusercontent.com/actuallymentor/battery/main/setup.sh | bash
```

> ⚠️ 기존 충전 제한 앱(AlDente 등)이 있으면 **먼저 제거**하세요. 두 앱이 같은 SMC 충전 키를 두고 충돌합니다.

설치되면 PowerMeter가 자동 감지하여 "충전 제어" 탭이 활성화됩니다.

## 구조

```
PowerMeter/
  Sources/main.swift   # 전체 앱 (단일 파일)
  build.sh             # swiftc → .app 번들 빌드
  AppIcon.icns         # 앱 아이콘
  iconmaker.swift      # 아이콘 생성기 (CoreGraphics)
  ROADMAP.md           # 기능 체크리스트
probe/                 # IOKit/SMC 탐색 스크립트 (개발 기록)
```

## 크레딧 / 라이선스

- 충전 제어 엔진: [actuallymentor/battery](https://github.com/actuallymentor/battery) (MIT)
- 본 프로젝트: [MIT](LICENSE)

> 충전 제어는 배터리 충전 동작을 변경합니다. 본인 책임 하에 사용하세요.
