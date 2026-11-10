# First-learners study (beginner-friendliness evidence)

This is the protocol for the five-to-eight-person study that would have to
happen before anyone claims Qorix is "the world's most beginner-friendly
code editor". It is designed to be run by one facilitator with a laptop and a
fresh learner, and measured against Thonny (the reference beginner Python
IDE) as the baseline.

**Nothing here has been run yet.** This document is the study kit, not the
results. Every number below is an expectation to check, not a finding.

---

## 1. What we are testing

The claim under test:

> A person who has never written code can install Qorix, write and run
> a short Python program, recover from their first error, and leave the
> session more confident than before — without any help beyond what the
> editor itself offers.

If learners routinely need a human to get past installation or their first
run, the claim is false. If they cannot finish the error-recovery task, the
friendly-error work is failing its one job. If confidence does not move, the
design did not feel friendly; it felt like a wall.

## 2. Participants

- 5–8 people who have **never written a line of code**.
- Mix ages: at least two under 16 (with a parent or guardian present and
  consenting), and at least two over 30.
- Nobody from the Qorix team. Nobody who has used Thonny, Mu, VS Code or
  this app before the session.
- Recruitment through a local library, a youth center or friends' kids. A
  €5 voucher per session is customary and removes awkwardness.
- Sibling/parent pairs are fine; only one participant per machine.

Exclusions: anyone who has written code for fun or at school beyond one
lesson; anyone who cannot be alone or does not give consent; anyone not
comfortable with English UI at the moment (localize the build first, then
recruit German/Spanish speakers — the app already ships those languages).

## 3. Consent (read verbatim)

> You are about to use a brand-new code editor. I want to see what happens,
> so I will watch and take notes. There is no test, you cannot fail, and
> nothing you write leaves this computer. I will not give you hints or
> answers unless you are truly stuck. You can stop at any time, for any
> reason. Is that okay? May I take notes on what you type and how long it
> takes? You do not have to say why you stopped.

Record: verbal yes/no. If no → end the session politely, no data recorded.

Data stored per participant: first name or initial, age band, session notes,
times, confidence self-reports, screenshots of nothing identifiable
(Face-blur any reflections). All on the facilitator's machine, never
uploaded, deleted on request.

## 4. Environment

Three machines or a VM set up identically:

1. **Qorix** — freshly exported Windows build or portable ZIP,
   `%APPDATA%` cleared, no Python pre-installed for the strictest version
   (baseline path: user must install Python or the editor guides them to it).
2. **Thonny** — the current stable release, same machine condition.
3. **Mu** — current stable release, same machine condition.

Same Python learner-facing goal on all three. If the test machine cannot run
a VM, use three disposable VMs of the same Windows version.

Ideal: one facilitator, one note-taker. The facilitator strictly does not
type, does not point at the screen, and does not say "try pressing X". When
the learner asks for a hint, give a **category hint** ("it is in the File
menu") before a **direct hint** ("press Ctrl+N"). Record which kind was
needed.

## 5. Scenario

> You are helping a friend who has never coded. Your task, from nothing to
> something: install the editor, get it to show your own name on the screen,
> then change it to show your favorite food.

Tasks, in order. Time from session start. Assistance level: none / menu-level
hint / direct-action hint / facilitator did it for them.

| # | Task | Done when |
|---|---|---|
| T1 | Get the editor onto the machine and open it | the editor window is open |
| T2 | Create a new file and write a line of Python that prints your name | text is in the editor |
| T3 | Run it and see your name printed | the output shows their name |
| T4 | Make a deliberate change: introduce a typo (`pront` or `1/0`) and get back to a working program | their name prints again |
| T5 | Say how confident you feel about coding now, out of 5 | a number |

Do **not** install Python for them. Do **not** explain what a print is until
they ask. Do **not** touch the keyboard.

### What "done" looks like for each task

- **T1** — Thonny/Mu typically win here (Thonny bundles Python; Mu is one
  installer). Qorix's beginner mode + install cards + winget button are
  the features under test. Watch: do they find the run button? Do they give
  up at the Python install step? Time to window-open is a separate metric.
- **T2** — Success = a file with a line like `print("Sam")`. Watch for: do
  they try the tutorial first (welcome screen)? Do they need syntax help?
  How long did the four-step tutorial take to click through verbally?
- **T3** — The critical first-run metric. Thonny passes instantly; Mu
  passes; Qorix passes if Run works and the output panel shows the
  print. Watch: did they find Run? Did they consider F5? Did an error appear
  instead?
- **T4** — The error-card test. Pre-seed the typo by suggesting the learner
  edit something; offer two options: rename `print` to `pront` (syntax
  error) or change a number to `1/0` (runtime error). Watch: do they press
  Run? Do they read the friendly error card or the raw traceback? Do they
  fix it with the card's help? How long does recovery take?
- **T5** — Ask "out of 5, how confident are you that you can make this
  print something else of your choosing?" and "out of 5, how confident were
  you before?" — the delta is the headline number.

## 6. Metrics to record per participant

| Field | Notes |
|---|---|
| age band | 6–12 / 13–17 / 18–29 / 30+ |
| group | Qorix / Thonny / Mu |
| install → window open | seconds |
| window → first typed program | seconds |
| first program → first run | seconds |
| typo introduced (T4) | name of it |
| T4 recovery time | seconds |
| T4 assistance level | none / menu hint / direct hint / facilitator-did |
| T4 did they use the friendly error card | yes / no / no idea it existed |
| confidence before → after | two 1–5 numbers |
| final comment | verbatim, one sentence |
| quit early | at which task, why |

## 7. Analysis

For each group (Qorix / Thonny / Mu), compute:

- median seconds for T1, T2+T3 (create + run), T4 (recovery);
- % of participants who recovered from the seeded error with no more than a
  menu-level hint;
- % who mentioned or visibly used the friendly error card (Qorix only);
- confidence delta (median before → median after);
- % who said something like "it was easy" or equivalent.

**The claim of "world's most beginner friendly" survives only if Qorix
is on par with Thonny on T1–T4 and ahead on confidence, or ahead on T3/T4
with a clear mechanism.** Anything less is marketing, not evidence. Report
what fails honestly — that is what the mod-platform's gate culture already
does, and it is the only credible posture for this claim.

## 8. What we already know before the study

- Qorix beats Thonny and Mu on: general-purpose language coverage,
  version history ("second chance" files), offline error explanations
  (de/es/en), and a designed tutorial.
- Qorix loses on: Python-out-of-box experience (Thonny bundles Python;
  Qorix needs winget or a pre-installed interpreter — **this is the
  risk being measured**), occupied-open-first impression, and the sheer
  breadth of UI to ignore on day one.
- Unknowns the study must answer: whether the winget path is discoverable;
  whether the welcome screen overwhelms or reassures; whether the friendly
  error cards are read or ignored; whether the four-step tutorial holds
  attention.

## 9. Where results go

- Raw notes and the filled table → `docs/archive/user-studies/<date>/`.
- A one-page summary with the numbers above → attached to the request card.
- Anything that reveals a bug (editor crashed, lesson blocked, Run hung)
  → filed as an issue in the same session, not "noted for later".

## 10. Facilitator script for T4 (typo seeding)

When the learner finishes T3, say:

> Now I want you to make the computer angry. Change the word `print` to
> `pront`, then run it again. What does it say?

Then, if they look stuck:

> What does that box [points to the diagnosis card only if they have already
> looked at the screen] tell you?

Do not point at the card. Do not explain the error. Record what they say
verbatim. Most beginners will laugh. Note whether they laughed.

---

**Next steps:** recruit, run, fill the table. Until this is done, this
document is the honest state of "beginner-friendliness evidence" for this
project.
