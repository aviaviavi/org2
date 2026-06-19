# Org2 meetings

Org2 Workspace records meetings as local corpus artifacts. The macOS app owns capture, local transcription, and durable file placement. OpenClaw or another agent owns later interpretation, summarization policy, and promotion into project/entity/task notes.

## Storage layout

By default the app writes under the selected corpus:

```text
meetings/
  2026-06-11-140000-scarf-reporting-sync.wav
  2026-06-11-140000-scarf-reporting-sync.org2
  2026-06-11-140000-scarf-reporting-sync.transcript.org2
```

Native recordings are mono 16 kHz WAV files so whisper.cpp can transcribe them directly. Imported audio keeps its original extension. The audio file stays inside the user-selected corpus. The app does not upload audio or transcripts.

## Meeting object

Each meeting note is an org2 node with `:kind: meeting` and links to its audio and transcript artifacts:

```org
#+TITLE: Meeting: Scarf reporting sync
#+ORG2_KIND: meeting

* Meeting: Scarf reporting sync
:PROPERTIES:
:ID: 8f7b3eb0-8f3f-4a4c-9e18-958c69f88201
:kind: meeting
:recorded_at: 2026-06-11T21:00:00.000Z
:duration_seconds: 1800.0
:audio_artifact: meetings/2026-06-11-140000-scarf-reporting-sync.wav
:transcript_artifact: meetings/2026-06-11-140000-scarf-reporting-sync.transcript.org2
:transcription_engine: whisper.cpp
:transcription_status: complete
:source: org2-workspace
:END:

** Summary
- Pending OpenClaw processing.

** Decisions
- [ ] Review transcript and extract decisions.

** TODOs
- [ ] Review this meeting transcript.

** Transcript
[[file:meetings/2026-06-11-140000-scarf-reporting-sync.transcript.org2][Open transcript artifact]]
```

The summary, decisions, and TODO sections are intentionally review placeholders in the first slice. Agents can use the transcript artifact to fill or promote them later.

## Transcript artifact

The transcript artifact is also org2 so it is searchable and easy for agents to cite:

```org
#+TITLE: Transcript: Scarf reporting sync
#+ORG2_KIND: meeting-transcript

* Transcript: Scarf reporting sync
:PROPERTIES:
:ID: 3be13af1-3509-4d48-b5a5-9960c726321d
:kind: meeting_transcript
:meeting_id: 8f7b3eb0-8f3f-4a4c-9e18-958c69f88201
:recorded_at: 2026-06-11T21:00:00.000Z
:audio_artifact: meetings/2026-06-11-140000-scarf-reporting-sync.wav
:transcription_engine: whisper.cpp
:transcription_status: complete
:source: org2-workspace
:END:

Transcript text...
```

## Local transcription

Transcription is local by default. Org2 Workspace resolves transcribers in this order:

1. `ORG2_WORKSPACE_WHISPER_COMMAND`, a custom local command. If it contains `{audio}`, the app substitutes the quoted audio path; otherwise it appends the audio path.
2. `whisper-cli` or `whisper-cpp` from whisper.cpp, with `ORG2_WORKSPACE_WHISPER_MODEL` or a common local `ggml-base.en.bin` path.
3. `whisper`, the OpenAI Whisper CLI, with `ORG2_WORKSPACE_WHISPER_MODEL` when set.

If no local transcriber is found, the app still writes the audio, meeting note, and transcript artifact with `:transcription_status: unavailable` and the local setup error. That preserves provenance without silently sending private meeting data anywhere.

## OpenClaw ingestion

Meetings live in normal corpus files under `meetings/`. The selected meeting note can be passed to OpenClaw Chat as workspace context, and OpenClaw can be configured separately to search, ingest, summarize, extract actions, or attach meeting outputs to daily notes, projects, entities, and agent threads.
