# 마피아 게임 — GitHub Pages + Supabase 최종본

이 버전은 파일명을 `index.html`, `app.js`, `styles.css`, `config.js`로 통일했고, 방 생성 시 학생 참가용 QR코드를 자동 표시합니다.

## Supabase 연결
처음 접속했을 때 Project URL과 Publishable(또는 anon) key를 입력하면 브라우저에 저장됩니다. 따라서 `config.js`를 직접 수정해 재배포할 필요가 없습니다.

QR 참가 링크에는 방 코드와 공개 Supabase 연결 정보가 함께 포함되어 학생 기기는 별도 설정 없이 접속합니다. `service_role` 또는 secret key는 절대 사용하지 마세요.

## 배포
ZIP의 파일을 GitHub 저장소 루트에 그대로 업로드하세요. 자세한 순서는 `배포순서.txt`를 확인하세요.

## Supabase SQL
마피아 DB/RPC를 처음 구성하는 경우 `supabase_setup.sql`을 SQL Editor에서 한 번 실행합니다. 기존 구축이 정상이라면 다시 실행할 필요는 없습니다.
