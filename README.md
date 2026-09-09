# 실시간 마피아 게임 — GitHub Pages + Supabase

Node.js 서버를 켜 둘 필요 없이 여러 기기가 인터넷으로 동시에 접속하는 버전입니다.

## 구성

- `index.html` : 게임 화면
- `app.js` : 게임 로직 / Supabase 통신
- `styles.css` : 디자인
- `config.js` : Supabase URL / 키 입력
- `supabase_setup.sql` : DB·RPC·Realtime 일괄 설치
- `assets/night.mp3` : 밤 BGM
- `assets/day.mp3` : 낮 BGM

## 1. Supabase 만들기

1. https://supabase.com 에서 새 프로젝트 생성
2. 프로젝트의 **SQL Editor** 열기
3. `supabase_setup.sql` 파일 전체를 붙여 넣고 **Run**
4. Project Settings → API에서 다음 두 값을 확인
   - Project URL
   - Publishable key (프로젝트에 따라 anon key로 표시될 수 있음)

## 2. config.js 수정

```js
window.MAFIA_CONFIG = {
  SUPABASE_URL: "https://xxxx.supabase.co",
  SUPABASE_KEY: "sb_publishable_xxxx"
};
```

**service_role / secret key는 절대 넣지 마세요.**
GitHub Pages에 들어가는 키는 브라우저에서 공개되므로 Publishable/anon key만 사용합니다.

## 3. GitHub Pages 배포

1. GitHub에서 새 repository 생성
2. 이 폴더 안 파일을 모두 repository 최상단에 업로드
3. GitHub repository → **Settings → Pages**
4. Build and deployment → **Deploy from a branch**
5. Branch `main`, folder `/(root)` 선택 → Save
6. 잠시 후 표시되는 `https://계정명.github.io/저장소명/` 주소로 접속

학생도 같은 주소로 접속한 뒤 5자리 방 코드와 이름/별명을 입력하면 됩니다. 실제 학생 이름 대신 별명을 사용하면 개인정보 저장을 줄일 수 있습니다.

## 게임 흐름

진행자:
`방 생성 → 참가자 대기 → 게임 시작 → 밤 → 마피아 → 경찰 → 의사 → 아침 → 토론 → 투표 → 결과 → 다음 밤`

참가자:
- 역할은 자기 기기에서만 조회
- 마피아: 공격 대상 선택
- 경찰: 조사 후 결과를 자기 화면에서 확인
- 의사: 치료 대상 선택
- 낮: 생존자 투표
- 사망 후 행동 불가

## BGM

진행자 기기에서만 재생됩니다.

- 밤 ~ 의사: `assets/night.mp3`
- 아침 ~ 투표 결과: `assets/day.mp3`
- 단계가 바뀌면 자동 전환
- 음량 슬라이더 / 배경음 끄기 제공

브라우저 정책 때문에 첫 자동재생은 막힐 수 있습니다. 진행자가 게임 시작/다음 단계 버튼을 누르는 순간부터 정상 재생됩니다.

## 데이터 보안 구조

공개 테이블과 비밀 테이블을 분리했습니다.

- `public.players`: 이름 / 생존 여부만 저장
- `private.player_secrets`: 개인 token / 역할 저장
- `private.actions`: 마피아·경찰·의사·투표 선택 저장
- `private.room_secrets`: 진행자 token 저장
- 비밀 데이터는 직접 SELECT 권한을 주지 않음
- 브라우저는 허용된 RPC만 호출
- 역할 조회 RPC는 각 기기에 저장된 긴 랜덤 player token을 검사
- Realtime은 역할이 아닌 `room_events`의 새 이벤트만 전달

교실 게임용 익명 인증 구조입니다. 실제 사용자 계정·민감정보를 다루는 서비스라면 Supabase Auth 기반 로그인까지 추가하는 것을 권장합니다.

## 문제 해결

### "Supabase 연결 설정이 필요합니다"
`config.js` 값이 아직 기본값입니다.

### 방이 만들어지지 않음
`supabase_setup.sql`을 Supabase SQL Editor에서 실행했는지 확인합니다.

### 실시간 갱신이 느림
Realtime 이벤트 외에 약 2.5초 간격의 자동 동기화를 같이 사용합니다. 일시적으로 Realtime 연결이 끊겨도 게임은 계속 갱신됩니다.

### 음악이 안 들림
브라우저 탭 음소거 여부와 기기 음량을 확인하고 진행자가 `게임 시작` 또는 `다음 단계` 버튼을 한 번 누릅니다.
