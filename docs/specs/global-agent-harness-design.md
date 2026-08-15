# 전역 Agent 설계·계획·실행 하네스 설계

- 작성일: 2026-08-13
- 상태: 사용자 승인 완료
- 범위: Hermes·Claude·Codex에서 공통으로 적용할 설계·계획·실행 규율과 사용자 관리 Superpowers fork
- 현재 설계 세션 runtime: `openai-codex / gpt-5.6-sol`
- 목표 기본 감독 runtime: `openai-codex / gpt-5.6-terra`, high effort

## 1. 목적

어떤 프로젝트나 폴더에서 작업을 시작해도 다음 운영 성질이 유지되는 전역 하네스를 만든다.

1. 기계적이고 가역적인 정확히 한 줄 수정 외의 모든 변경은 구현 전에 충분한 brainstorming과 구체적인 implementation plan을 거친다.
2. 설계 단계에서는 대안·리스크·사용자가 놓친 관점·실제 runtime·실패 경로를 적극적으로 찾는다.
3. 승인된 계획 뒤에는 routine confirmation과 중복 review로 병목을 만들지 않고 자율적으로 실행한다.
4. Hermes는 감독·분해·통합·직접 검증을 맡고, Claude CLI Opus5 worker가 계획된 구현·테스트 파일을 수정한다.
5. 독립 task는 Opus worker를 병렬 실행하되 mutable boundary가 겹치면 직렬화한다.
6. task마다 Codex Sol reviewer를 붙이는 직렬 루프는 기본 사용하지 않는다.
7. 사용자의 실제 goal을 폐기된 platform·과거 plan·repository의 dormant code로 대체하는 goal drift를 사용자 승인 단계보다 앞에서 차단한다.
8. 요청 밖의 좋은 개선안은 숨기지도, 몰래 구현하지도 않고 비실행 제안으로 제시한다.
9. Vault는 전체를 전역 prompt에 넣지 않고 관련 주제에서 index와 링크로 선택 조회한다.

## 2. 사용자에게 보이는 결과

### 2.1 변경 요청

```text
Read-only 질문·조사
→ 관련 skill과 필요한 근거만 읽음
→ 변경하지 않고 답변

기계적·가역적 정확히 한 줄 수정
→ 짧은 intent 확인
→ 한 줄 수정
→ focused verification

그 외 모든 변경
→ using-superpowers
→ brainstorming
→ 설계/spec 승인
→ writing-plans
→ implementation plan 승인
→ Hermes 감독 아래 Opus5 구현
→ Hermes 직접 검증
→ 결과와 비실행 제안 보고
```

### 2.2 승인된 plan 실행

사용자는 task마다 “계속할까요?”를 받지 않는다. Hermes는 승인된 plan 안에서 worker 실행, routine retry, 테스트, 통합, 로컬 verification을 계속한다.

사용자 개입은 다음처럼 사용자에게만 결정권이 있는 경계에 한정한다.

- 새로운 product·scope·architecture·policy 선택
- credential, OAuth, 2FA, payment, permission grant
- 승인되지 않은 real-data 변경
- publish, push, deploy, external send
- 승인되지 않은 irreversible external effect
- automation으로 볼 수 없는 physical-device observation
- 증거로 해소할 수 없는 승인 요구사항 간의 실제 모순

실패한 테스트, worker timeout, parser 오류, plan-compatible 보정은 사용자 decision gate가 아니다.

## 3. 설계 원칙

### 3.1 계획 전에는 느려도 철저하게

brainstorming과 planning은 실행 중 되돌아갈 안전망이 아니라, 실행 전에 불확실성과 잘못된 방향을 제거하는 선행 gate다. 시간과 token을 아끼기 위해 설계 깊이를 줄이지 않는다.

설계 단계에서는 다음을 반드시 다룬다.

- observable user goal
- authoritative runtime과 delivery path
- current behavior와 approved behavior delta
- 명시적 non-goals
- meaningful alternatives와 recommendation
- trade-offs와 reversibility
- data·security·deployment·physical boundary
- failure behavior와 rollback
- testing과 acceptance evidence
- parallel ownership과 integration order
- 사용자가 놓친 risk·대안·knowledge gap

### 3.2 계획 뒤에는 빠르게

승인된 implementation plan은 실행 계약이다. routine detail 때문에 brainstorming을 다시 열거나 사용자에게 반복 승인을 요청하지 않는다.

plan-compatible 문제는 Hermes가 evidence를 수집하고 안전한 retry 또는 계획된 fallback으로 처리한다. 새 사용자 결정이 필요한 경우에만 정확한 결정 질문을 제시한다.

### 3.3 제안과 실행을 분리한다

YAGNI는 제안을 금지하지 않는다.

- 요청되지 않은 파일·폴더·필드·규칙·기능은 구현하지 않는다.
- 의사결정에 중요한 blind spot, risk, missing requirement, alternative, improvement는 숨기지 않는다.
- 승인 범위 밖 아이디어는 `Non-executing proposal`로 명확히 표시한다.
- 제안에는 필요성, trade-off, reversibility, 가장 작은 다음 단계를 포함한다.
- 승인 전에는 spec·plan·implementation scope에 편입하지 않는다.

간결한 보고는 narration을 줄이는 규칙이지, 결정에 필요한 reasoning·alternative·proposal을 제거하는 규칙이 아니다.

### 3.4 외부 패턴과 upstream 이름을 보존한다

Superpowers의 기존 skill 이름과 주요 component를 유지한다. 사용자 정책 변경은 `Hong policy extension`으로 식별한다. upstream update는 자동 overwrite하지 않고 diff 검토 후 선택 병합한다.

## 4. 작업 분류와 발동 조건

### 4.1 Read-only

설명, 조사, 비교, 현재 상태 확인처럼 artifact를 바꾸지 않는 작업이다. 관련 skill을 먼저 확인하되 full design/plan artifact는 만들지 않는다.

조사 결과 변경이 필요해지면 변경 경로로 새로 분류한다.

### 4.2 One-line mechanical exception

아래를 모두 만족할 때만 full design/plan gate를 생략할 수 있다.

1. 실제 diff가 정확히 한 줄이다.
2. 의도, 대상 파일, 기대 결과, 검증법이 이미 명시되어 있다.
3. 선택해야 할 product·architecture·workflow·policy 의미가 없다.
4. security·data·deployment·model routing·전역 설정을 바꾸지 않는다.
5. local하고 가역적이다.
6. 인접 파일·schema·interface 변경이 필요하지 않다.

한 조건이라도 불확실하면 full gate다. 구조·전역 정책·workflow·security·data·deployment 변경은 줄 수와 관계없이 항상 full gate다.

### 4.3 Full Design and Plan Gate

One-line mechanical exception이 아닌 모든 변경에 적용한다.

```text
using-superpowers
→ brainstorming
→ written spec approval
→ writing-plans
→ written implementation plan approval
→ approved-plan execution
```

독립적으로 시작한 Hermes·Claude·Codex 세션에는 같은 gate를 적용한다. Hermes가 승인된 plan에서 추출한 bounded task를 전달한 worker는 brainstorming을 반복하지 않고 task brief를 즉시 실행한다.

## 5. 하네스 계층과 소유권

### 5.1 전역 헌법

`SOUL.md`는 항상 필요한 짧은 원칙만 소유한다.

- skill-first routing
- one-line exception과 full gate trigger
- approved-plan autonomy
- Goal Fidelity
- proposal duty
- Hermes supervisor / Opus implementation 역할
- Vault 선택 조회 진입 규칙

세부 절차를 `SOUL.md`에 중복하지 않는다.

### 5.2 사용자 관리 Superpowers fork

`hongs-hermes-setup`이 다음 skill의 사용자 관리 정본을 보관한다.

```text
using-superpowers
brainstorming
writing-plans
executing-plans
subagent-driven-development
dispatching-parallel-agents
verification-before-completion
```

역할:

| Skill | 사용자 정책상의 책임 |
|---|---|
| `using-superpowers` | 응답·조사·계획·실행 전 relevant skill 확인과 full gate trigger |
| `brainstorming` | goal·runtime·대안·risk·non-goal·검증을 설계하고 written spec 승인 획득 |
| `writing-plans` | 승인 spec을 worker message까지 포함한 유일한 implementation plan 정본으로 변환 |
| `executing-plans` | 승인 plan을 routine prompt 없이 끝까지 실행 |
| `subagent-driven-development` | task별 2단계 review loop가 아니라 plan-defined Opus task 실행·보정·통합 orchestration |
| `dispatching-parallel-agents` | disjoint mutable boundary를 plan에서 판정하고 병렬 group 실행 |
| `verification-before-completion` | Hermes의 fresh evidence와 goal clause별 완료 gate |

### 5.3 Hermes 운영 adapter

다음 기존 custom skill도 같은 정책으로 정렬한다.

```text
plan
supervised-agent-workflow
mixed-model-agent-orchestration
subagent-coding-context
execution-continuity
```

| Skill | 정렬 내용 |
|---|---|
| `plan` | `/plan`과 “계획만” 요청용 비실행 adapter. brainstorming이 없으면 먼저 보내며, 계획 규격은 `writing-plans`를 사용 |
| `supervised-agent-workflow` | task별 independent reviewer 기본값 제거. Goal Fidelity와 Hermes 직접 검증 중심 |
| `mixed-model-agent-orchestration` | Terra supervisor, Claude CLI Opus5 implementer, Sol exceptional adjudication |
| `subagent-coding-context` | worker brief 필수 필드와 GOAL_CONFLICT/OUT_OF_SCOPE/GOAL_DRIFT_REJECTED 계약 |
| `execution-continuity` | 승인 plan 뒤 routine user prompt 제거와 비실행 proposal 처리 |

## 6. Goal Fidelity Lock

### 6.1 문제 정의

Goal substitution은 사용자의 observable goal을 repository에 존재하는 다른 platform, 폐기된 historical plan, architecture migration, infrastructure work로 바꾸는 오류다.

회귀 사례:

```text
요청된 observable goal:
- iPad 브라우저 WebUI에서 삭제 프로젝트가 휴지통에 프로젝트 1행으로 보인다.
- 해당 프로젝트 소속 회의록은 별도 행으로 중복 표시되지 않는다.

금지된 목표 대체:
- 폐기된 iPad MAUI 계획 재개
- WebUI 동작 수정 대신 platform migration
```

사용자 approval gate에서 이를 발견하면 이미 시간과 token을 낭비한 뒤다. plan과 worker dispatch 단계에서 차단해야 한다.

### 6.2 Plan 필수 계약

모든 implementation plan은 시작 부분에 다음을 구체적인 값으로 작성한다.

```md
## Goal Fidelity Lock

Authoritative observable goal:
- [사용자의 실제 결과]

Authoritative runtime:
- [실제 surface와 delivery path]

Runtime evidence:
- [사용자 확인, production entry point/caller, running/deployed artifact]

Approved behavior delta:
- Before: [현재 관찰]
- After: [승인 결과]

Explicit non-goals:
- [폐기 platform·plan]
- [인접하지만 요청하지 않은 기능]
- [repository에 존재하지만 active runtime이 아닌 후보]

Forbidden substitutions:
- [migration, framework conversion, infrastructure replacement 등]
```

### 6.3 Authority order

자료 간 충돌 시 다음 우선순위를 사용한다.

1. current direct user goal
2. user-approved current spec
3. verified runtime and production caller
4. current approved implementation plan
5. project instructions
6. historical handoff, plan, worktree, branch name
7. dormant or deprecated repository code

낮은 순위 자료는 높은 순위 goal의 구현 근거로 사용할 수 있지만 goal 자체를 바꾸지 못한다.

### 6.4 Task traceability

각 task는 다음을 명시한다.

```md
Goal clause served:
Why this file is necessary:
Runtime caller evidence:
Forbidden adjacent route:
```

모든 changed path와 material line은 observable goal 또는 승인된 prerequisite에 직접 연결되어야 한다.

다음은 정당화 근거가 아니다.

- cleaner
- more complete
- future-proof
- related
- already present in the repository
- platform name similarity

### 6.5 Worker prompt header

모든 implementation worker 메시지는 다음 의미로 시작한다.

```text
You are implementing an approved bounded task, not choosing the product goal.

AUTHORITATIVE GOAL:
[exact observable goal]

AUTHORITATIVE RUNTIME:
[exact runtime and evidence]

DO NOT SUBSTITUTE:
[stale/dormant platforms and historical plans]

Every changed file must directly trace to the goal.
If the goal cannot be reached inside the assigned route, return GOAL_CONFLICT.
Do not implement an alternative route.
```

### 6.6 Drift 검사와 거부

worker 결과를 통합하기 전에 Hermes가 다음을 검사한다.

1. changed paths가 plan allowlist 안에 있는가?
2. authoritative runtime caller에서 changed file까지 실제로 도달 가능한가?
3. 각 변경이 approved behavior delta를 직접 만드는가?
4. deprecated platform·worktree·historical plan을 활성화하지 않았는가?
5. 요청 결과 대신 migration·refactor·framework conversion을 만들지 않았는가?

실패 결과는 사용자 decision gate로 넘기지 않고 자동 거부한다.

```text
GOAL_DRIFT_REJECTED
- observed drift:
- violated goal clause:
- unauthorized runtime/path:
- discard these changes:
- resume from approved task:
```

계획에 미리 작성된 correction worker message로 같은 approved task를 재시도한다.

## 7. Planning Contract

`writing-plans`가 implementation plan의 유일한 상세 규격을 소유한다.

### 7.1 필수 section

- Goal Fidelity Lock
- observable goal and explicit non-goals
- actual runtime and evidence
- approved architecture and constraints
- repository/file responsibility map
- task dependency graph
- parallel groups and serialization points
- exact create/modify/test paths
- interface consumes/produces contract
- TDD or red-capable check for behavior changes
- exact verification commands and expected evidence
- worker ownership matrix
- complete first-dispatch worker message per task
- correction/retry worker message per task
- GOAL_CONFLICT and OUT_OF_SCOPE report format
- Hermes direct verification steps
- backup, rollback, external-effect gate
- user decision boundaries
- non-executing proposal handling
- final requirement-to-evidence matrix

### 7.2 Worker message까지 계획에 포함

각 task에는 실제 전달 가능한 worker 메시지 전문을 둔다.

- worker role and canonical route
- exact goal and task goal clause
- authoritative runtime and evidence
- allowed/forbidden paths
- required context sources and question mapping
- exact implementation steps
- exact tests and commands
- allowed/forbidden side effects
- parallel group and shared boundary
- required skills
- final report schema

Hermes가 실행 중 open-ended prompt를 새로 설계하지 않는다.

### 7.3 No placeholders

다음은 계획 실패다.

- `TBD`, `TODO`, `later`
- “적절한 error handling”
- “필요한 test 작성”
- “Task N과 유사하게”
- 실제 path·symbol·command가 없는 단계
- worker가 product 또는 architecture 결정을 추론해야 하는 빈칸
- task와 goal clause 연결이 없음

### 7.4 Self-review

계획 작성자는 실행 전 다음을 자체 점검한다.

1. spec coverage
2. placeholder scan
3. path and symbol validity
4. interface consistency
5. task dependency consistency
6. ownership overlap
7. runtime reachability
8. Goal Fidelity traceability
9. verification red capability
10. external side-effect and user gate completeness
11. worker message completeness
12. proposal/implementation separation

작성된 plan은 사용자 승인을 받아야 실행 계약이 된다.

## 8. 실행 역할과 모델 routing

### 8.1 Hermes supervisor

목표 runtime은 `openai-codex/gpt-5.6-terra`, high effort다.

Hermes가 소유한다.

- current user goal
- brainstorming and spec
- implementation plan
- worker task decomposition and complete messages
- process monitoring
- changed-path and Goal Fidelity checks
- integration decisions
- actual command/test execution
- completion evidence
- user escalation and non-executing proposals

Hermes는 계획된 product source/test 파일을 직접 수정하지 않는다. worker 실패 시 plan에 정의된 bounded correction message로 Opus worker를 재실행한다.

### 8.2 Claude CLI Opus5 implementation worker

사용 경로:

```text
Claude Code CLI
→ authenticated subscription-backed first-party route
→ `claude -p --model opus`
→ canonical model/provider probe 통과
```

금지:

- Hermes native Anthropic delegation을 대체 경로로 사용
- MoA Anthropic reference 사용
- Anthropic API-key route로 자동 fallback
- Extra Usage 활성화 또는 유료 fallback
- architecture·product·release 결정
- plan 밖 파일 수정
- worker 자체 brainstorming

worker는 승인된 task의 source/test edit만 소유한다.

### 8.3 Codex Sol

Codex GPT-5.6 Sol은 기본 reviewer가 아니다. 다음에만 사용한다.

- user explicitly requests it
- plan predefines a bounded high-risk adjudication
- evidence conflicts and Hermes cannot resolve it through direct measurement
- required verification evidence remains materially insufficient

routine task마다 Sol review를 실행하지 않는다.

## 9. 병렬화와 isolation

### 9.1 병렬 조건

두 task는 다음이 모두 성립할 때만 병렬 group에 들어간다.

- write paths are disjoint
- inputs are independent
- neither task consumes the other's output
- no shared DB, server, fixture, lockfile, generated output, package artifact, migration, release target
- each has its own red-capable focused check
- integration interface is fixed in the approved plan

하나라도 거짓이면 직렬화한다.

### 9.2 Workspace

병렬 writer는 각각 isolated worktree를 사용한다. shared source directory에서 동시 write하지 않는다.

plan이 각 worker의:

- worktree/branch naming rule
- owned paths
- base revision
- no-commit 또는 commit policy
- result artifact/report location
- integration order

를 지정한다.

### 9.3 Integration

Hermes는 worker self-report를 완료 증거로 취급하지 않는다.

1. inspect actual status/diff/artifact
2. run changed-path allowlist check
3. run Goal Fidelity check
4. run focused verification
5. integrate in plan order
6. run integration/full gate

## 10. Review Economy and Verification

### 10.1 Default path

```text
approved plan
→ Opus implementation
→ Hermes direct artifact/diff/caller verification
→ Hermes fresh tests and requirement evidence
```

현재 `subagent-driven-development`의 task별 implementer + spec reviewer + quality reviewer + final reviewer loop는 제거한다.

### 10.2 Exceptional review

별도 reviewer는 다음에만 사용한다.

- plan이 특정한 high-risk boundary
- conflicting worker evidence
- direct verification cannot establish a required clause
- explicit user request

가능하면 bounded read-only Opus review를 사용한다. Sol은 exceptional adjudication으로 남긴다.

### 10.3 Completion gate

완료 주장은 다음 fresh evidence 뒤에만 가능하다.

- every goal clause mapped to evidence
- every changed path traced to a goal clause or approved prerequisite
- exact focused checks run
- integration/full planned gates run
- forbidden paths and substitutions absent
- generated/live artifacts inspected when applicable
- automated proof separated from physical/live proof
- unresolved skips and risks reported

## 11. 실행 실패와 사용자 decision gate

### 11.1 Hermes가 자율 처리하는 것

- expected RED test
- implementation test failure
- parser/type/lint failure
- worker timeout or malformed report
- plan-compatible local repair
- isolated worktree cleanup
- safe local retry
- worker disagreement resolvable by evidence

### 11.2 사용자에게 묻는 형식

계획에 없는 사용자-owned decision이 필요할 때만 다음 packet을 제시한다.

```text
Decision required:
Evidence:
Options:
Trade-offs:
Reversibility:
Recommended choice:
```

`plan collapsed` 또는 `premise failed` 같은 추상 표현만으로 user gate를 만들지 않는다. 필요한 새 결정의 내용이 구체적이어야 한다.

### 11.3 Proposal duty

실행 중 material improvement가 발견됐지만 현재 goal에 필수적이지 않으면 다음처럼 보고한다.

```text
Non-executing proposal:
Why it matters:
Trade-offs:
Reversibility:
Smallest next step:
Implementation performed: no
```

현재 승인 task를 방해하지 않으며 별도 승인이 없으면 실행하지 않는다.

## 12. Vault 선택 라우팅

전역 하네스는 Vault 전문을 자동 로드하지 않는다.

`HONG_VAULT_ROOT`는 각 PC의 shared Vault root를 가리키는 Windows 사용자 환경 변수다. 비밀값이 아니다.

관련 주제에서:

1. `${HONG_VAULT_ROOT}/wiki/index.md`를 읽는다.
2. 현재 질문에 관련된 page와 link만 따른다.
3. 사용한 knowledge는 `[[페이지]]`로 표시한다.
4. Vault knowledge와 live-system/external evidence를 구분한다.

금지:

- Vault 전체 자동 로드
- `raw/` 자동 로드
- `AI 기초 개념.md` 자동 로드
- 승인 없이 Vault write

환경 변수가 없으면 Vault 조회 불가를 표시하고 다른 evidence만으로 계속한다.

## 13. 사용자 관리 fork와 upstream update

### 13.1 정본

`hongs-hermes-setup`이 사용자 관리 하네스 skill의 canonical source다. `<LOCAL-APP-DATA>/hermes/skills`는 적용 runtime이다.

각 forked skill은 다음 provenance를 기록한다.

- upstream repository/source identifier
- upstream version or SHA-256
- Hong policy extensions
- last reviewed date

### 13.2 Update 절차

```text
upstream update detection
→ old upstream / new upstream / Hong fork diff
→ bug fix·feature와 policy conflict 분류
→ non-executing merge proposal
→ user approval
→ selected merge
→ static and behavior tests
→ baseline manifest revision update
→ runtime apply after separate approval where required
```

upstream update가 사용자 정책을 자동으로 덮어쓰지 않는다.

## 14. Verification Matrix

| Scenario | Expected behavior |
|---|---|
| typo 한 줄 수정 | full plan 없이 focused verification |
| 두 줄 config 수정 | brainstorming부터 시작 |
| 한 줄 model routing 변경 | full gate |
| 한 줄 global policy 변경 | full gate |
| independent Hermes/Claude/Codex feature session | own brainstorming + spec + plan |
| approved bounded Opus worker | no brainstorming; execute complete task brief |
| two independent task owners | complete messages + separate worktrees + parallel execution |
| shared file or runtime | serialized tasks |
| worker activates MAUI for WebUI trash goal | GOAL_DRIFT_REJECTED before user gate |
| worker test failure | plan-compatible correction without routine user prompt |
| credential or unapproved publish | user decision gate |
| good out-of-scope idea | non-executing proposal |
| completion claim | fresh Hermes verification evidence |
| upstream Superpowers update | diff proposal, no automatic overwrite |

## 15. 적용 단계

### Phase 1 — 하네스 자체 구현·검증

- create the local `hongs-hermes-setup` skeleton needed only for harness source
- materialize the approved user-managed skill fork
- align Hermes adapter skills
- add the concise SOUL trigger/role/proposal/Vault-entry rules
- preserve the existing graphify rules while adding only the minimum independent-session design/plan trigger to the global Claude `CLAUDE.md` and Codex `AGENTS.md`
- add static policy checks and behavior probes
- apply to the local Hermes runtime only after the implementation plan's live-config/runtime gate
- verify new independent Hermes, Claude, and Codex sessions load and route correctly

### Phase 2 — 기존 전역화 초안 재설계

검증된 새 하네스로 다음을 처음부터 다시 brainstorm하고 plan한다.

- Vault global routing and `HONG_VAULT_ROOT`
- SOUL/Claude/Codex global instruction adapters
- Terra supervisor / Opus parallel implementation routing
- `hongs-hermes-setup` full baseline structure
- approved 20 custom skills
- shared config boundary
- `hongs-vault` publication boundary
- GitHub → Actions → Supabase release flow

기존 `2026-08-13-home-ai-environment-sync-design.md`와 `2026-08-13-hongs-environment-repositories.md`는 참고 자료일 뿐 새 하네스를 우회하는 승인 계약으로 사용하지 않는다.

## 16. 첫 구현 범위와 비범위

### 16.1 첫 구현 범위

- user-managed harness fork source
- listed Superpowers and Hermes adapter skill alignment
- concise SOUL harness rules
- minimum Claude/Codex independent-session harness triggers, preserving current graphify instructions
- provenance metadata
- static policy validation
- representative behavior probes
- disposable verification and local runtime apply gate

### 16.2 비범위

- GitHub repository creation or push
- Supabase schema, Storage, Action secrets
- website implementation
- Vault publication
- full 20-skill baseline materialization
- live model/provider config mutation
- Anthropic Extra Usage activation
- production deployment

## 17. 성공 기준

하네스 구현은 다음이 모두 실측으로 확인될 때 성공이다.

1. 새 Hermes session에서 relevant skill-first routing이 작동한다.
2. two-line 변경 prompt가 brainstorming과 written plan gate를 건너뛰지 않는다.
3. one-line global policy/model routing 변경도 full gate를 사용한다.
4. approved bounded worker prompt가 brainstorming을 반복하지 않는다.
5. implementation plan에 complete worker and correction messages가 포함된다.
6. default task-by-task independent reviewer loop가 없다.
7. disjoint Opus tasks만 병렬화된다.
8. Goal Fidelity example에서 MAUI substitution이 user gate 전에 거부된다.
9. Hermes가 worker report가 아니라 diff·caller·tests로 완료를 검증한다.
10. out-of-scope improvement가 비실행 proposal로 남는다.
11. user intervention이 승인되지 않은 decision/external boundary에만 발생한다.
12. baseline fork와 installed runtime hashes가 일치한다.
13. secret·credential·runtime state가 baseline에 들어가지 않는다.
14. upstream update가 Hong policy를 자동 overwrite하지 않는다.
