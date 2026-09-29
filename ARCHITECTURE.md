# Architecture

## Dispatch model

The Master Router exposes a single webhook and four scheduled/manual triggers.
Each entry point passes through a normalization node that flattens the payload
into a common shape, then a tagging node that stamps an `event_type`. A single
switch dispatches on that tag.

This means every pipeline shares one normalization contract and one logging
convention. Adding a pipeline is a new switch branch, not a new workflow with its
own copy of the boilerplate.

| Branch | Trigger | Purpose |
|---|---|---|
| A | Webhook `new_booking` | Booking received → send intake form link |
| B | Webhook `tally_form_submission` | Form submitted → AI risk triage |
| C | Webhook `inbound_whatsapp` | Patient message → conversational AI reply |
| D | Cron 09:00 Cairo | Tomorrow's appointments → pre-visit reminder |
| E | Cron every 30 min | Visits 1–3h ago → post-visit follow-up |
| F | Cron 09:00 Cairo | Visits 5–7 days ago → care check-in |
| G | Manual | Manager broadcast / VIP follow-up / missed-appointment nudge |
| H | Fallback | Unrecognized event → log + admin alert |

---

## Branch A — Booking intake

```
Webhook → Respond 200 → Extract & validate → Skip check
   → Check record exists → Merge → Already submitted?
        ├─ yes → "we already have your details"
        └─ no  → send form link → INSERT patient_intake → log
```

Validation normalizes the phone to E.164 with the Egypt country code, rejects
anything under 10 digits, and enforces quiet hours. The skip path is a clean exit,
not an error.

The existence check queries for both `existing_id` and `form_submitted` in a single
round trip rather than two sequential queries.

---

## Branch B — Intake and risk triage

```
Webhook → Respond 200 → Extract form fields → Validation error?
   → Check duplicate (24h) → Duplicate?
   → Build triage prompt → LLM → Parse envelope
   → Risk router ─┬─ emergency → manager alert
                  ├─ high      → priority alert
                  └─ normal    → continue
   → INSERT patient_intake → Google Sheets → patient confirmation → log
```

The prompt constrains the model to a fixed JSON schema. The parse node strips
code fences, attempts `JSON.parse`, and on failure emits a `medium` risk envelope
with a staff note flagging manual review — the safe direction to fail in a clinical
context.

`risk_level` is a `CHECK`-constrained column, so an unexpected model output is
rejected at the database boundary as well.

---

## Branch C — Conversational AI

```
Webhook → Extract message → Load memory (last 20 turns) + patient profile
   → Build chat payload → LLM → Parse
   → Save user turn + AI turn → Update patient record → Log operations
   → Send reply
   → Route extra actions ─┬─ escalate    → notify manager
                          ├─ review      → send review link
                          └─ rebook      → hand off to booking
```

Memory is loaded with a single CTE that returns both the transcript array and the
patient profile row as JSON, avoiding a second query.

The model returns `reply`, `intent`, `sentiment`, `sentiment_score`, `escalate`,
`send_review_link`, `booking_ready`. Side effects are driven by these boolean
fields, never by pattern-matching the reply text — so a patient writing the word
"manager" does not trigger an escalation, but a genuinely frustrated message does.

---

## Branch D — Pre-visit reminder

```
Cron 09:00 → SELECT tomorrow's patients (reminder_sent IS NULL, not opted out)
   → Split in batches → Form submitted?
        ├─ yes → prep-instruction reminder
        └─ no  → form-completion reminder
   → Send → UPDATE reminder_sent → loop
```

The batch loop marks each patient before advancing. A crash mid-run resumes without
re-messaging anyone already marked. The `WHERE reminder_sent IS NULL` guard is
repeated in the `UPDATE` itself, closing the race between send and mark.

---

## Branches E & F — Follow-up cascade

Stage 1 sweeps every 30 minutes for visits that ended 1–3 hours ago. The `LEFT JOIN`
against `patient_followup` excludes anyone already contacted, and the insert uses
`WHERE NOT EXISTS` as a second guard.

Stage 2 runs daily for visits 5–7 days old, generating a personalized care message
through the LLM based on visit type.

Both respect `opted_out` and cap batch size (50 and 100 respectively) so a backlog
cannot produce a message flood.

---

## Data model

Eight tables. The design principle throughout is that **state lives in columns, not
in workflow variables** — every "has this already happened?" question is answerable
by a single indexed query, which is what makes the workflows restartable.

| Table | Role |
|---|---|
| `clinic_patients` | Patient roster and visit records |
| `patient_intake` | Intake form + triage output + lifecycle flags |
| `appointments` | Booking ledger |
| `conversations` | State-machine cursor per patient |
| `conversation_memory` | Rolling transcript for AI context |
| `patient_followup` | Follow-up cascade + sentiment |
| `clinic_operations_log` | Business event stream (JSONB) |
| `automation_logs` | Technical audit trail |

`clinics` + `v_clinic_routing` map a WhatsApp instance to a clinic, so one n8n
deployment serves multiple practices.

See [`schema/schema.sql`](schema/schema.sql).

---

## Failure handling

| Concern | Mitigation |
|---|---|
| Gateway retries | 200 returned before processing |
| Duplicate sends | Unique constraints + `IS NULL` guards |
| Booking races | Advisory lock inside `book_appointment()` |
| LLM downtime | Retry ×3, then safe-default envelope |
| Malformed model output | Dedicated parse node, `CHECK` constraint at DB |
| Partial batch failure | `onError: continueRegularOutput` per node |
| Silent failure | Every branch writes to `automation_logs` |
| Off-hours messaging | Quiet-hours gate before every send |
