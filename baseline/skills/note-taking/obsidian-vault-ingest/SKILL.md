---
name: obsidian-vault-ingest
description: 새 Obsidian 원본을 승인 후 위키에 인제스트한다.
version: 0.1.0
author: HongGyu, Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [Obsidian, Vault, Ingest, Knowledge-Base]
    related_skills: [obsidian]
---

# Obsidian Vault Ingest

새 원본을 `raw/`에서 읽어 사용자의 수집 의도를 먼저 확인하고, 승인 뒤에만 `wiki/`의 출처·연결·개관을 갱신한다. 이 skill은 원본을 편집하거나 일괄 처리하지 않는다.

## When to Use

- 사용자가 새 Obsidian 원본을 인제스트, 정리, 위키화해 달라고 요청할 때.
- `raw/`에 새 파일을 넣었고 그 파일을 지식베이스에 반영하려 할 때.
- 기존 `/injest` 또는 `/ingest` 표현을 포함한 요청.
- Do not use for: 위키에 이미 있는 내용을 묻는 요청은 `obsidian-vault-query`, 건강 점검은 `obsidian-vault-lint`를 사용한다.

## Prerequisites

1. Vault의 절대 경로를 확인한다. 먼저 `OBSIDIAN_VAULT_PATH`를 확인하고, 없으면 Obsidian의 vault 목록 또는 사용자가 지정한 경로를 확인한다.
2. Vault 루트의 프로젝트 규칙과 대상 폴더의 규칙을 읽는다. 최소한 루트 `CLAUDE.md` 또는 `AGENTS.md`, `raw/CLAUDE.md`, `wiki/CLAUDE.md`를 실제 존재하는 파일 기준으로 읽는다.
3. `raw/`는 사용자 소유의 불변 원본이다. 수정, 이동, 삭제, 파일명 변경, 처리 표시 추가를 하지 않는다.

## Procedure

1. **대상 하나를 확정한다.** 사용자가 경로를 지정했으면 그 파일을 사용한다. 지정하지 않았고 후보가 여러 개면 목록을 보여 주고 선택을 받는다. 기본은 한 번에 원본 하나다.
   - 완료 기준: 처리할 `raw/`의 원본 하나가 확정됐다.
2. **수집 의도를 먼저 읽는다.** 원본의 `## 왜 담았는가`와 `## 인제스트 지시`를 본문보다 먼저 읽는다. 둘 중 필요한 지시가 비어 있거나 모호하면 본문 처리 전에 사용자에게 묻는다.
   - 완료 기준: 무엇을 남기고 무엇을 무시할지 확인됐다.
3. **원본을 분석하고 영향 범위를 조사한다.** 원본 전문과 필요한 이미지/첨부만 읽고, `wiki/index.md`에서 관련 진입점을 찾은 뒤 필요한 링크만 따라간다. Vault 전체를 읽지 않는다.
   - 완료 기준: 핵심 주장, 근거 상태, 기존 페이지와의 관계·모순 후보가 확인됐다.
4. **쓰기 전 보고하고 승인받는다.** 다음을 짧고 구체적으로 제시한다: 핵심 요점, 만들 `type: source` 페이지, 갱신할 기존 페이지·특수 파일, 새 페이지 후보, 모순·불확실성, 제외할 내용. 이 단계에서는 어떤 위키 파일도 쓰지 않는다.
   - 완료 기준: 사용자가 제안한 변경 범위를 승인했다.
5. **승인 범위만 반영한다.** `wiki/`에 source 페이지를 만들거나 갱신한다. 모든 일반 페이지에는 `type`, `tags`, `created`, `updated`, `sources`, `confidence` frontmatter와 첫 문장 요약을 둔다. source 페이지의 `sources`에는 해당 원본을 `[[raw/...]]`로 연결한다.
   - 기존 서술과 새 근거가 충돌하면 삭제·덮어쓰기 대신 양쪽을 병기하고 상충을 명시한다.
   - 새 개념은 실제로 필요할 때만 만들고 관련 `[[링크]]`를 연결한다.
   - 사용자가 직접 검증하지 않은 정보는 `confidence: verified`로 올리지 않는다.
   - 완료 기준: 승인된 지식 페이지가 source와 상호 연결됐다.
6. **파생 문서를 갱신한다.** `wiki/index.md`, 추가 전용인 `wiki/log.md`, `wiki/overview.md`를 갱신한다. 원본이 전체 논지에 영향을 주는 경우에만 `wiki/synthesis.md`도 갱신한다.
   - 완료 기준: 새 source가 index와 log에 반영됐고, overview/synthesis 변경 여부가 근거와 함께 결정됐다.
7. **검증한다.** 수정 파일만 다시 읽어 필수 frontmatter, source 링크, index 항목, log 항목, 관련 링크를 확인한다. `raw/`에 변경이 없음을 확인한다.
   - 완료 기준: 수정 경로와 검증 근거, 남은 불확실성이 보고됐다.

## Page Contracts

- `wiki/`는 평면 구조다. 주제별 하위 폴더를 만들지 않는다.
- 파일명은 구체적인 한국어 명사구를 사용한다.
- `concept`은 한 문장 주장으로 요약될 때만 쓴다. 여러 주장의 묶음은 실제 하위 페이지가 생긴 뒤에만 `moc`로 만든다.
- 태그·type·confidence 값은 해당 Vault의 `wiki/CLAUDE.md` 정본을 따른다. 새 축·값·스키마는 임의로 만들지 않는다.
- `Output/`은 팀 독자를 위한 별도 결과물이다. 위키 페이지를 그대로 복사하지 않으며, 사용자가 요구한 경우에만 작성한다.

## Pitfalls

- 원본의 처리 여부를 `raw/`에 표시하지 않는다. 미처리 여부는 `raw/` 목록과 `wiki/index.md`의 Sources를 대조해 판단한다.
- 원문 기반 패턴을 구현할 때 이름·구성 요소를 임의로 바꾸지 않는다. 확장은 먼저 제안하고 원문과 명확히 구분한다.
- 출처 없는 일반론을 새 위키 페이지로 늘리지 않는다. 재사용 가치와 근거가 있는 판단만 남긴다.
- 사용자가 일괄 처리를 명시하지 않았다면 여러 원본을 한 번에 처리하지 않는다.

## Verification

보고에는 다음을 포함한다.

- 처리한 원본의 `[[raw/...]]` 링크
- 새로 만들거나 갱신한 위키 페이지 목록
- `index.md`, `log.md`, `overview.md`, `synthesis.md`의 변경 여부와 이유
- 확인한 상충·미검증 정보·사용자 확인이 필요한 다음 판단
- `raw/` 미수정 확인
