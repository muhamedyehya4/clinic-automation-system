# Clinic Automation System

A WhatsApp automation platform for dental clinics. It replaces the manual
receptionist loop — booking, medical intake, risk triage, reminders, and
post-visit follow-up — with an event-driven system built on n8n, PostgreSQL, and
an LLM inference layer. Conversation flows are designed for Egyptian Arabic.

**148 workflow nodes across 4 pipelines · 8-table Postgres schema · 7 trigger paths**

## Status & credits

Built with a team of four. I (Mohamed Yehya, [@muhamedyehya4](https://github.com/muhamedyehya4))
owned the system architecture and workflow design. Tested end-to-end; not deployed
in production. This repo contains the n8n workflow templates; the dashboard source
is not included.

---

## The problem

A mid-size clinic loses money in three specific places:

| Leak | Cause | What this system does |
|---|---|---|
| No-shows | Nobody reminds the patient | Automated reminder the day before, branched on whether intake is complete |
| Chair time wasted on paperwork | Medical history collected in the waiting room | Intake form sent at booking; doctor sees it before the patient arrives |
| Silent churn | Unhappy patients never complain, they just don't return | Post-visit sentiment analysis; negatives escalate to the manager, positives get a review link |

The receptionist bottleneck is the root of all three. Every path here is designed
to run without a human in the loop, and to escalate to one when it matters.

---

## Architecture

```
                    ┌──────────────────────────────┐
   WhatsApp ───────▶│   MASTER ROUTER (webhook)    │
   Intake form ────▶│   + 3 cron triggers          │
   Manager cmd ────▶│   + manual trigger           │
                    └──────────────┬───────────────┘
                                   │  normalize → tag → switch
        ┌──────────┬───────────┬───┴───┬───────────┬──────────┐
        ▼          ▼           ▼       ▼           ▼          ▼
       (A)        (B)         (C)     (D)         (E/F)      (G)
    Booking     Intake      Convo   Pre-visit   Follow-up   Manager
     intake    + triage      AI     reminder     cascade    broadcast
        │          │           │       │           │          │
        └──────────┴───────────┴───┬───┴───────────┴──────────┘
                                   ▼
                    PostgreSQL  ·  Evolution API (WhatsApp)
                                   │
                              automation_logs
```

Every branch terminates in a log write. Nothing fails silently.

Full breakdown: **[ARCHITECTURE.md](ARCHITECTURE.md)**

---

## Pipelines

### 1. Master Router — `workflows/01-master-router.json`
81 nodes. Seven independent pipelines behind one dispatcher.

Consolidating seven separate workflows into a single router removed duplicated
normalization and error-handling logic that had drifted out of sync across
copies. One webhook, one dispatch switch, one logging convention.

Triggers: inbound webhook · daily 9AM cron · daily day-5 cron · 30-minute
post-visit sweep · manual manager trigger.

### 2. Appointment Booking Agent — `workflows/02-appointment-booking-agent.json`
25 nodes. Conversational booking over WhatsApp.

An LLM classifies each message into `book` / `reschedule` / `cancel` / `unclear`
and extracts date, time, and doctor. Partial information is held in a `conversations`
row and the bot asks only for what's missing — so "Tuesday with Dr. Ali" and
"actually make it 4pm" resolve to a single booking across two messages.

Writes go through the `book_appointment()` stored procedure, which takes an
advisory lock before checking slot availability. Two patients messaging at the
same second cannot both be told the slot is free.

### 3. Intake & Risk Triage — `workflows/03-intake-risk-triage.json`
19 nodes. Medical form submission → structured clinical risk assessment.

The LLM returns a strict JSON envelope: `risk_level`, `risk_score`, `red_flags`,
`staff_note`, `prep_instructions`. Routing is on the parsed field, never on
free-text matching.

- `emergency` → immediate WhatsApp alert to the manager
- `high` → flagged alert, appointment prioritized
- otherwise → prep instructions to the patient, note filed for the doctor

Deduplicated on a 24-hour window so a double form submission can't fire two alerts.

### 4. Follow-Up AI Reply Handler — `workflows/04-followup-ai-reply-handler.json`
23 nodes. Stateful post-visit conversation.

Loads the last 20 turns from `conversation_memory` plus the patient profile,
then classifies intent and sentiment. Negative sentiment escalates to the manager
with the transcript. Positive sentiment sends the Google review link. Booking
intent hands off to pipeline 2.

---

## Engineering decisions worth calling out

**Idempotency is enforced in the schema, not in the workflow.**
`uniq_intake_phone_date`, `ON CONFLICT DO NOTHING`, and `WHERE reminder_sent IS NULL`
mean a webhook replay or a cron overlap cannot produce a duplicate message. n8n
retries are safe by construction.

**Webhooks respond 200 before doing any work.**
Every webhook path hits `Respond 200 OK` as its first downstream node, then
continues processing asynchronously. WhatsApp gateways retry aggressively on slow
responses; without this the system would duplicate messages under load.

**LLM output is parsed defensively.**
Every AI call is followed by a dedicated parse node that strips markdown fences,
extracts the JSON envelope, and falls back to a safe default. A malformed model
response degrades to a neutral path instead of throwing.

**Quiet hours are enforced before send.**
Messages are suppressed between 23:00 and 08:00 Cairo time. A booking made at
2AM queues its confirmation rather than waking the patient.

**SQL injection is handled at the boundary.**
Every user-supplied string passes through a `safe*` variable that escapes quotes
before interpolation. The booking pipeline goes further and uses true parameterized
queries (`$1, $2, …`).

**Retry with backoff on every outbound call.**
All WhatsApp sends are `maxTries: 3` with a 2-second wait. `onError:
continueRegularOutput` keeps a failed send from killing the rest of a batch.

---

## Stack

| Layer | Choice | Why |
|---|---|---|
| Orchestration | n8n (self-hosted) | Visual DAG the clinic manager can audit without reading code |
| Database | PostgreSQL 14 | JSONB for conversation context, advisory locks for booking races |
| Messaging | Evolution API | WhatsApp gateway |
| Inference | Groq | Sub-second latency; a chat reply that takes 8s reads as broken |
| Forms | Tally | Webhook-native, no custom frontend needed |
| Export | Google Sheets | Clinic staff already lived in spreadsheets |

---

## Running it

```bash
# 1. Database
psql -U postgres -d clinic -f schema/schema.sql

# 2. Environment (n8n → Settings → Variables)
EVOLUTION_API_URL=https://your-evolution-host
EVOLUTION_API_KEY=your_key
CLINIC_BACKEND_URL=https://your-backend
GROQ_API_KEY=your_groq_key
INTAKE_FORM_URL=https://tally.so/r/your_form

# 3. Import workflows
#    n8n → Workflows → Import from File → workflows/*.json
#    Then attach your Postgres credential where marked
#    REPLACE_WITH_YOUR_CREDENTIAL_ID

# 4. Point your WhatsApp gateway webhook at the Master Router path
```

---

## Repository layout

```
clinic-automation-system/
├── README.md
├── ARCHITECTURE.md          # node-by-node pipeline breakdown
├── workflows/               # 4 importable n8n workflow definitions
│   ├── 01-master-router.json
│   ├── 02-appointment-booking-agent.json
│   ├── 03-intake-risk-triage.json
│   └── 04-followup-ai-reply-handler.json
└── schema/
    └── schema.sql           # full Postgres DDL
```

---

## Notes

All credentials, endpoints, and clinic-identifying details have been replaced with
environment variable references. The workflows are exported in a deactivated state
and are import-ready.
