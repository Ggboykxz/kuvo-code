# What people do with Kuvo Code

End-to-end cases, written from what people ask of a coding agent and a Mac app, not from how
the code is laid out. Each runs in the e2e copy of the app (see README.md) with a real model, on
real open-source projects cloned into the run's folder. Status: ✅ passes, ⚠️ works with friction
(noted), ❌ broken (noted, then fixed), ⏳ not run yet, ⛔ can't run here (why).

## A. First launch and setup

| ID | Case | Status |
| --- | --- | --- |
| A1 | Open the app for the first time: the engine downloads, the window explains what to do next, and a free model is ready without an account | ✅ fixed on the way: the model picker listed models you can't use (680ef6a) |
| A2 | Start chatting right away with no account, from the first screen | ⏳ |
| A3 | Look for how to connect Claude, ChatGPT or an API key, and find where each account's usage shows | ⏳ |
| A4 | Bring over an existing opencode setup from Settings › General | ⏳ |
| A5 | Change the theme, the accent and the text size, and see them apply everywhere | ⏳ |
| A6 | Quit with work running and open again: the conversation and the queue are as they were | ⏳ |

## B. Working on a project

| ID | Case | Status |
| --- | --- | --- |
| B1 | Open a project folder (drag it in, or New Project) and ask "what does this project do, and how is it organized?" | ✅ GLM, slugify |
| B2 | "Run the tests and tell me what fails" on a project with a failing test | ✅ DeepSeek, textstats (a seeded bug): both failures found and explained |
| B3 | "Fix this bug: …" from a real issue's text, then check the fix | ✅ fixed both, tests re-run green |
| B4 | "Add a --json flag to the CLI and a test for it" | ✅ a --lines flag in textstats: a helper, the flag, two tests and a README line; the tests pass and the output has "lines" |
| B5 | Review the changes: open the diff, comment on a line ("rename this"), send the comments, see them handled | ✅ comment on a line, sent with an empty composer, handled; ❌→✅ Accessibility press on the mode/model menus hung until the menu closed (fadfbd9) |
| B6 | Undo the last turn's changes, then change your mind | ✅ undo restores only that turn's files, Redo brings them back; ❌→✅ outside git the dialog promised files back the engine can't restore (26a90bc) |
| B7 | "Commit this with a good message", then make a branch | ✅ Commit… with Suggest a Message, then New Branch… from the title bar |
| B8 | Start a session in a worktree, work there, and merge it back | ✅ worktree session, Merge into main, Archive and Remove Worktree; ❌→✅ the archived session lost its project (2321ca2); removal threw away changes made after the check (a5077ea) |
| B9 | Plan first ("plan how to add dark mode, don't change anything"), then switch to Build and carry it out | ✅ Plan changed nothing, Build It carried it out |
| B10 | Ask First: allow a command once, always allow another, deny an edit with a reason | ✅ allow once, always, deny; ❌→✅ Always Allowed listed nothing (523f32e); a piped command showed as two (773d689) |
| B11 | The agent asks questions before starting ("which database should I use?") and you answer in the card | ✅ two questions: number key picks, typing writes your own, Return sends |
| B12 | Queue follow-ups while it works, steer it mid-task, stop it with Esc, resume | ✅ queue with ⌘↩, Steer, Esc stops, Resume, ↑/↓ history; ❌→✅ Send Now only in ⋯ for a next-step message (45b9548) |
| B13 | Two sessions in the same project working at once, and one in another project | ✅ two sessions in tinysite and one in textstats at once, each with its own permission cards ("Waiting for you" in the sidebar) and the right result; ❌→✅ Always Allow for everything read "Don't ask again for: *" (a8d4c86) |
| B14 | Switch model or effort mid-conversation | ✅ picked another free model mid-conversation, applied when the picker closes, next reply on it; ⚠️ the notice names the model by its id ("Switched to deepseek-v4.1-flash-free") |
| B15 | "Start the dev server and show me the page": the page in the panel's browser | ❌→✅ the agent couldn't click or type in the Mac browser since 0.5.6 (3edd9f4); a page that didn't open said only "browser is empty" (3f59090); its dev server left running showed nowhere (14ed231) |
| B16 | A long conversation: scrolling, finding text (⌘F), and the context filling up and compacting | ❌→✅ Find's Next/Previous didn't scroll to a result out of view (fixed by the performance work, ea28e93, rechecked); Summarize Now works and the agent still knows what it did |
| B17 | A folder that isn't a git repository, a folder with spaces and accents in its name, and a big repository | ✅ accents and spaces in the folder name; ❌→✅ outside git the Changes tab stayed empty (8ad10d1) |
| B18 | Rename, archive, restore and delete sessions; find one with ⌘K | ✅ rename (accents), archive, search finds it, unarchive, delete asks first, ⌘K finds files and sessions; ❌→✅ a deleted session stayed under In Conversations; a search typed at launch found nothing (8149536) |
| B19 | "Use a subagent to research X while you do Y" | ✅ the subagent has its own row (task, agent, what it used) and its findings come back in the reply |
| B20 | Custom commands and skills: add one, use it with / | ✅ a command made in Settings › Commands, offered after /, Tab to add words, filled into its prompt |

## C. Files and attachments

| ID | Case | Status |
| --- | --- | --- |
| C1 | Attach a screenshot of a bug ("make it look like this") | ✅ the picture shows in your message, and the model described it correctly |
| C2 | Attach a PDF or a CSV and ask about it | ❌→✅ three .md reports vanished from the sent message and the agent didn't know where they were (b8aee60) |
| C3 | Drop several files, paste a picture from the clipboard, remove one before sending | ✅ three files in the composer, one removed, the other two sent and read; ❌→✅ the remove button was hover-only, out of VoiceOver's reach (6de8dcc); pasting from the clipboard not run (it would replace yours) |
| C4 | Quote part of a reply and answer it | ✅ Reply quotes the answer above your message; the agent knew what it referred to |
| C5 | Browse the project's files in the panel and open one | ✅ Files from the new tab page, the filter, a file opens colored with its folder path |
| C6 | The agent shows you a file or folder in the panel ("show me where that's configured") | ✅ "show me that file in the panel": the agent opened index.html there itself |

## D. Chats (no project)

| ID | Case | Status |
| --- | --- | --- |
| D1 | Ask a general question, then a follow-up | ✅ a chat question and a follow-up that needs the first answer |
| D2 | "Write a regex for …" and copy the code | ✅ a Python regex with a test, run by the agent; the code block has line numbers, colors and Copy Code (not pressed, to keep your clipboard) |
| D3 | "Make a chart of this data" or "a small game": a widget in the conversation | ✅ a live chart in the conversation |
| D4 | A chat that turns into work: Move to Project | ✅ moved into a project with its conversation; the agent then works there |

## E. The browser

| ID | Case | Status |
| --- | --- | --- |
| E1 | "Find the latest release of X and what changed" (the agent browses and reads) | ⏳ |
| E2 | "Fill in this form with …" on a real form page | ✅ httpbin's pizza form: seven fields, submitted, the echo matches |
| E3 | Upload a file to a website for you (a bot on this Mac) | ✅ see L22 |
| E4 | Download a file from a page and work with it | ✅ downloaded through the browser and read; the e2e copy now downloads into its run's folder |
| E5 | A site that needs your sign-in: the card, Take Over, Hand Back | ⚠️ Google and X refused the headless shell; the machine browser is full Chrome now (a94a15b), sign-in to recheck with a real account |
| E6 | Browse yourself in the panel: tabs, back, the new tab page, a page's dialog | ✅ a page's confirm in a bar with Cancel and OK, the address field, Back, the camera attaching a screenshot of the page |
| E7 | Upload a file to a website from a bot on a machine | ✅ upload from a session on a machine (full Chrome, the-internet.herokuapp.com); the same tools as a bot's |

## F. Bots

| ID | Case | Status |
| --- | --- | --- |
| F1 | Make a bot from scratch: it asks what its purpose is, you tell it, it keeps it | ✅ the bot writes first: infers its job from its name or asks (f95ed69) |
| F2 | Start from a template (the morning news digest) and send its job | ✅ Herald from Start From: its job typed in its composer, sent; it asked for topics in a question card, sent a first digest of five with links, and set a daily 8:00 wake-up |
| F3 | "Remind me in 2 minutes to stretch": a wake-up arrives on time | ✅ see L15 |
| F4 | "Every weekday at 9 …": a repeating wake-up, shown in Edit Bot, paused and resumed | ✅ see L16 and L17; shown in Edit Bot, Pause Wake-Ups holds them (a `paused` mark) and turning it off resumes; ❌→✅ the switch had no name for VoiceOver (014d6b9) |
| F5 | "Tell me when this page changes": a watch that wakes the bot when it does | ✅ see L8–L11 |
| F6 | Change a bot's job by telling it; change its look, name, personality and model | ✅ told a new job in its conversation: job and memory updated, a weekday 10:00 wake-up set; renamed, new look, personality and model in Edit Bot, and it answers as its new self on the new model |
| F7 | Export a bot and import it as a new one | ✅ a .kuvobot opened from Finder starts New Bot with its name, look and personality, its job waiting in the composer; Export's save panel runs in a system process the driver can't reach, so the file was written in its format |
| F8 | Delete a bot | ✅ Delete Bot… asks first; the bot, its conversation and folder go (the folder to the Trash) |
| F9 | A bot on a machine: works and wakes while the Mac's app is closed | ⏳ |
| F10 | Bots writing to each other: one asks another for something and gets an answer | ⏳ |

## L. What bots can get done

Real jobs people give bots, each run for real with the bot's own tools, to find out whether it has
what it needs to finish them. A bot that can't do a job well (a missing tool, a step it can't
take, a result it can't deliver) is a finding even when nothing crashes.

### Research and reports

| ID | Job | Status |
| --- | --- | --- |
| L1 | "Every morning, send me the top 5 tech news stories with links" (browsing several sources, deduplicating, a short digest) | ⏳ |
| L2 | "Compare the price of the Sony WH-1000XM6 at three stores and tell me the cheapest" | ⚠️ an answer with links, but 50 steps and 5 minutes (it pressed Tab through Amazon's page) |
| L3 | "Read this article (a URL) and give me the five key points" | ✅ GLM, Wikipedia via webfetch |
| L4 | "What changed in the latest release of a GitHub project? Summarize its release notes" | ✅ GLM, through GitHub's API |
| L5 | "Find three good libraries for X, compare them in a table, and recommend one" | ✅ three libraries in a table, one recommended, 29 s |
| L6 | "Research a question and write the report to a file I can open" (sources, how sure it is) | ✅ a sourced report with how sure it is, opened in the panel |
| L7 | "Look up the opening hours and address of a place and put them in my notes file" | ✅ official hours and address, in notes.md, opened in the panel |

### Watching for changes

| ID | Job | Status |
| --- | --- | --- |
| L8 | "Tell me if this website goes down" (status code) | ✅ a 5-minute watch on the status code, wakes only on a change |
| L9 | "Tell me when this product's price drops below €X" | ✅ asked which book it meant (a question card) before watching |
| L10 | "Tell me when a new issue is opened on this GitHub repository" | ✅ a 30-minute watch on GitHub's API, with the newest issue as its baseline |
| L11 | "Watch this RSS feed and send me new posts" | ✅ a 5-minute watch on the feed; posts already there kept as seen |
| L12 | "Tell me when this file in my project changes" | ⏳ |
| L13 | "Warn me 30 days before this domain's certificate expires" | ✅ a warning 30 days before, and a daily watch in case the certificate changes |
| L14 | "Check my CI every hour and tell me when it fails" | ⏳ |

### Schedules

| ID | Job | Status |
| --- | --- | --- |
| L15 | "Remind me in 2 minutes to stand up" (a one-off, on time) | ✅ fired 43 s after the minute (wake-ups are checked each minute); the bot then reminded |
| L16 | "Every weekday at 9" / "every Monday" / "every 2 hours" (repeats, listed, in the right time zone) | ✅ weekdays at 9 and every 2 hours, listed |
| L17 | "Move my morning reminder to 8:30" and "stop the hourly one" (changing and canceling by asking) | ✅ moved to 8:30, the 2-hour watch canceled, the list shows it |
| L18 | "What do you have scheduled?" (it lists its wake-ups and watches) | ✅ lists its wake-ups with kuvo-wake |
| L19 | A wake-up due while Kuvo Code was closed: it runs when the app opens | ⏳ |

### Files and data

| ID | Job | Status |
| --- | --- | --- |
| L20 | "Here's a CSV of my expenses: total by category and chart it" (an attached file, a widget) | ⏳ |
| L21 | "Download the CSV on this page and tell me what's in it" | ✅ downloaded with curl, counted 200 rows, averaged, opened it in the panel |
| L22 | "Upload this file to this website's form" (a real upload page) | ✅ a bot on this Mac made notes.txt and uploaded it (the-internet.herokuapp.com) |
| L23 | "Rename the photos in this folder by date" (files in a folder you give it) | ✅ renamed by date |
| L24 | "Turn this JSON into a spreadsheet-friendly CSV" | ✅ users.csv in its workspace, shown in the panel |
| L25 | "Make me a one-page summary as a file I can share" | ❌→✅ no way to make a PDF (it drove Microsoft Edge from a shell); browser_save_pdf now (569e34c), a designed one-pager saved; GLM can still take several minutes to write a long document |

### Code

| ID | Job | Status |
| --- | --- | --- |
| L26 | "Keep this project's build green: run the tests every hour; when they fail, fix it on a branch and tell me" | ⏳ |
| L27 | "Review the changes on this branch before I merge" (Lens) | ⏳ |
| L28 | "Check every week whether this project's dependencies are out of date" | ⏳ |
| L29 | "Write the release notes from the commits since the last tag" | ⏳ |
| L30 | "Find the TODOs in this project and list them by priority" | ✅ five TODOs across three files, sorted by priority |

### The web, by hand

| ID | Job | Status |
| --- | --- | --- |
| L31 | Fill in and send a multi-step form | ✅ see E2 |
| L32 | A page behind a cookie banner, a popup and a new window | ✅ a new window, switched to, its heading read |
| L33 | A site that needs the user's sign-in (the card), then work behind it | ⏳ |
| L34 | A one-time code from the user | ⏳ |
| L35 | A table spread over several pages, or loaded as you scroll | ❌→✅ right count, but 38 steps and 5 minutes scrolling each page; with browser_text pointed out, 5 steps and 54 s |
| L36 | Take a screenshot of a page and show it to me | ⚠️ the screenshot shows only inside the folded browser step; "show it to me" should show it in the reply |
| L37 | A page's own dialog (alert, confirm) | ✅ a JS confirm, declined, the page's result read back |

### People and other bots

| ID | Job | Status |
| --- | --- | --- |
| L38 | It needs a decision: it asks plainly and stops, and carries on when you answer | ✅ asks what it needs (a question card) before booking |
| L39 | "Ask Sage to research X and tell me what it finds" (bot to bot, and the answer back) | ✅ asked Reader and relayed its answer (Reader's answer itself was wrong: a model mistake) |
| L40 | A bot reports back to the session that asked it for something | ⏳ |
| L41 | It finishes while you're in another app: a notification you can answer | ⏳ |

### Memory and the job

| ID | Job | Status |
| --- | --- | --- |
| L42 | "I'm vegetarian and live in Istanbul": it remembers next time, after a restart | ✅ remembered across launches; ❌→✅ its web search failed: the engine had no search provider (2821561) |
| L43 | A watch's last value kept between wake-ups, so it reports only what's new | ⏳ |
| L44 | Its job grows ("also check the weekend weather") and the sidebar line follows | ✅ the new Friday wake-up added, the sidebar line follows |
| L45 | It's asked to change its name or model: it says plainly it can't, and where you can | ❌→✅ said it can't and pointed to Edit Bot, but suggested models you have no account for; now it leaves the choice to Edit Bot's list |

### On a machine, and when things go wrong

| ID | Job | Status |
| --- | --- | --- |
| L46 | A bot on a machine does a job and wakes itself up while the Mac's app is closed | ⏳ |
| L47 | Upload and download on a machine's browser | ⏳ |
| L48 | The site it uses is down: it says so, and tries again later | ⏳ |
| L49 | A long job (many steps, many pages) finishes without losing the thread | ⏳ |
| L50 | The app quits mid-job; on reopening, the job carries on or says where it stopped | ⏳ |

## G. Group chats

| ID | Case | Status |
| --- | --- | --- |
| G1 | Make a group chat, ask it to decide something, and watch the bots talk it through | ✅ two bots talked it through and came to a decision |
| G2 | Say "go ahead" and the work is handed out; each bot does its part and reports back | ⏳ |
| G3 | Undo a message, stop the chat, keep it going | ⏳ |
| G4 | A meeting on a schedule | ⏳ |

## H. Integrations and tools

| ID | Case | Status |
| --- | --- | --- |
| H1 | Add a well-known MCP server with no account from Popular Servers and use it | ✅ Context7 from Popular Servers, its two tools used in a session; ❌→✅ every Add read "Add" to VoiceOver (182a4c0) |
| H2 | Add your own MCP server (a command) and use its tools | ⏳ |
| H3 | An MCP server that asks you something mid-task | ⏳ |
| H4 | Add a skill from GitHub and use it | ⏳ |
| H5 | Integrations that need an account: what you see before and after | ⏳ |

## I. Remote machines

| ID | Case | Status |
| --- | --- | --- |
| I1 | Add a Linux machine over SSH; its engine installs | ⏳ |
| I2 | A project on the machine: ask, edit, run tests, review the changes, use its terminal | ⏳ |
| I3 | The machine drops off and comes back mid-task | ⏳ |

## J. When things go wrong

| ID | Case | Status |
| --- | --- | --- |
| J1 | The network goes away mid-reply | ⏳ |
| J2 | A model that fails or is gone (an error to read, a way forward) | ❌→✅ the composer showed the default model while every message went to the missing one, and picking another hid Try Again (f8feef7, 1132f77); now Choose a Model, and Try Again answers on the new model |
| J3 | The engine stops; the app brings it back | ✅ the engine killed mid-session came back on its own within seconds; the next message went through |
| J4 | Very large output from a command, a huge file, a binary file in the changes | ✅ 3 million lines from seq: the engine kept the tail for the agent and the whole log in Kuvo Code's data folder (pruned after a week); a 30 MB file and a binary in the changes, app idle at 0% CPU; ❌→✅ both showed an empty header, as if empty, and folding was out of VoiceOver's reach (4e0f33a) |

## K. Settings, menus and the rest

| ID | Case | Status |
| --- | --- | --- |
| K1 | Every Settings page opens, reads well, and keeps what you change | ✅ all 22 Settings pages open with their content |
| K2 | Every menu command and keyboard shortcut does what it says | ✅ every menu shortcut matches Settings › Keyboard Shortcuts and the docs; menu commands need the window in front (a copy in the background has them greyed), so pressed only through the palette and launch hooks |
| K3 | Notifications: a finished task and a question while you're in another app | ⏳ |
| K4 | The menu bar's usage panel | ⏳ |
| K5 | Storage: see what takes room, clear it | ✅ sizes add up to what's on disk; Delete… on Logs asks, then leaves only the live log; "Other" is mostly MCP servers' npm cache, described on hover |
| K6 | Passwords: save one for a site, use it, remove it | ✅ on a local login page: Save this password?, filled with the key, no second offer, listed and deleted in Settings; ❌→✅ every copy shared one creator code, so a demo or test copy listed (and could delete) the passwords saved in the app (6546e76); Delete read "Trash" to VoiceOver |
