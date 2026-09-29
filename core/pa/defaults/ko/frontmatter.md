# Frontmatter 규칙

새 문서의 frontmatter는 프로그램이 만든다. AI는 아래 값만 정한다 (properties).

## type
- 문서 종류. 소문자 영어, 여러 개 가능.
- 자주 쓰는 값: idea, meeting, project-note, decision, reference, log, plan, question
- 기존 vault 예: `assignment`, `quiz`, `cloud-service-design` 처럼 구체적인 값도 쓴다.

## project
- 01-projects 아래 폴더명과 같은 이름 (예: beta, alpha). 없으면 null.

## tags
- 꼭 필요할 때만. 소문자, 공백 대신 `-`. 계층은 `/` (예: `travel/japan`).

## 프로그램이 자동으로 붙이는 값
- date: 처리한 날짜
- source: assistant
- confidence: AI가 매긴 확신도 (0~1). 기준값보다 낮으면 `99-assistant/assistant.base` 의 "확인 필요" 뷰에 나온다.
- meeting 이면 categories: "[[Meetings]]" (Meetings.base 연동)
