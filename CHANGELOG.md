# Changelog

What changed in each release, for people using Kuvo Code. Add changes people would notice under
Unreleased, in plain words about what they'll see, as part of the change itself. Before a
release, Unreleased is renamed to the version; the release notes come from that section.

## Unreleased

- Approve All runs what Settings › Permissions sets to Ask First without asking, as its name says; it used to ask anyway. Don't Allow in Settings now holds in every session: one set to Ask First used to ask about it instead.
- With Outlook and Microsoft 365 connected, every message used to carry all 196 of its tools, about 280,000 tokens, so sessions were slow and costly and small models ran out of room. Now the agent looks up the tool it needs, and each message is about 30 times smaller. Integrations you added earlier get this, and any newer version of their server, on their own.
- In a narrow window, each Settings page's title stays lined up with the settings under it.
- A draft waiting in the composer opens with the cursor after it, instead of all selected, when the window takes a moment to come forward.

## 0.5.1

- Messages waiting for the agent sit in a card tucked behind the composer, with a picture's thumbnail when one is attached. Steer gives a queued message to the agent at its next step without waiting for the run to end, the trash removes it, and ⋯ has Send Now and Edit; double-click a message to edit it.
- Pictures and files you attach in a session on a machine reach its agent: they used to fail with "Unable to read attachment". What the model can read goes with the message; anything else is copied to the machine for the agent to open.

## 0.5.0

- Settings has tabs, like your sessions: each page you open gets a tab of its own beside the others (⌘-click opens one more, even when it's open), and so does a site you sign in to for the agent; ⌃Tab, ⌘1 to ⌘9 and ⌘W work there too, and your tabs are there the next time. Pages line up under their titles.
- Signing in to X, LinkedIn or Reddit for the agent happens right in Settings › Integrations, which shows whether you're signed in on this Mac and on each machine, live as you sign in.
- X opens on your machines: a page opened there at an address used to stay blank on sites that turn headless browsers away.
- Settings › Integrations shows how each one is doing on this Mac and on each machine ("Connected on this Mac and my-server"), with one button when something needs you and the rest in a ⋯ menu. **Sign In…** for a service the agent uses on its site opens it right in Settings, for this Mac or one of your machines, instead of a panel tab that didn't show.
- Settings › Integrations shows Sign In… for Gmail and Google Calendar until you've signed in (they used to say Connected), and says when Outlook hasn't been signed in yet.
- A key you save for an integration reaches the engine and your machines' engines on its own, once whatever's working there is done; there's no Restart Engine button to remember.
- **Integrations work the way you'd expect**: once you connect one, the agent uses its tools directly, on this Mac and on your machines, instead of opening the service's website. Integrations you added before are switched over when Kuvo Code starts.
- Find (⌘F) marks each place your words are, right in the text (replies, code, tables and your messages), the one you're on in orange, with a bar in the corner that counts the results.
- A widget takes shape as the agent writes it, then comes alive when it's done.
- What an agent writes to another shows in its conversation, as "To Scout" with the message, and the answer when it waited for one.
- ⌘F finds in group chats too, as in sessions.
- **Agents write to each other**: any session or bot, on this Mac or a machine, can see who else there is and send one a message, then wait for its answer or carry on. A message from another agent shows who it's from, with Open to go to its conversation. Two agents can't keep writing back and forth unattended.
- **Agents make things you can see and play with**, right in the conversation: charts, diagrams, mockups, small apps and games, or choices to click, drawn live where they made them, in sessions and group chats. What you click in one can answer the agent for you.
- The usage panel does less work: it reads only what's new in Claude and Codex logs, and finds their accounts without holding up launch.
- Kuvo Code runs opencode 2.0.31, with fixes for MCP servers, configured instructions, long conversations and models' reasoning settings.
- **Chats**: conversations of no project, for a question or an idea. Start one with **+** next to Chats or ⌥⌘N; when it turns into work, **Move to Project** carries it, conversation and all, into one of your projects.
- Sidebar sections fold: click Bots, Chats, Projects or Recents to tuck it away.
- With the tab bar hidden, the side panel's button stays at the top right of the window, so the panel is easy to find.
- **Bots**: teammates with a name, a look of their own and one job. Make one with **+** next to Bots in the sidebar: pick its color, shape and face, say what it does, and have it live on this Mac or on one of your machines, in a folder of its own or one of your projects. A bot keeps one conversation, remembers what it learns in a memory file, and can schedule its own wake-ups to carry on later; on a machine, it wakes up and works while your Mac is off. Its steps show when it schedules a wake-up, and each wake-up shows in its conversation.
- **Bots come alive**: a bot's avatar shows what it's up to. It bounces with sparks circling it while it works, hops and glows when it needs you, cheers when it has news, and sleeps with z's floating up until its next wake-up. Idle, it breathes, blinks, looks around and fidgets now and then, and it notices when you point at it. The sidebar counts down to its next wake-up and shows when it's waking up.
- **Group chats for bots**: with two bots or more, start one from **+** next to Bots. Write to the group and its bots talk it through, one at a time, answering each other; the lead goes first and sums up at the end, @name asks someone directly, and a bot with nothing to add stays quiet. Write while they talk and the one talking reads it at once; long discussions pause until you say Keep Going. Afterwards, each bot remembers the chat, so you can ask it about one in its own conversation.
- In group chats, @mentions stand out: the bot's name in its own color, and in its messages, its face in place of the @. A group chat can also say what it's for, and its bots keep that in mind.
- In group chats, your messages have the time, Copy and **Undo From Here** under the pointer, as in a session; bots' messages have Copy. Undo takes the chat back to before your message and puts it in the composer, and the bots set aside what was taken back.
- In group chats, what a bot did on its turn shows above its message, like "Searched the web 3 times, fetched 2 pages", and opens to each step. When a bot names you ("@User"), it stands out in your accent color.
- **Each bot has a model**, picked when you make it or in Edit Bot. Group chats use it; in a bot's own conversation you can still pick another.
- **Personalities for bots**: pick how a bot talks, like Straight Shooter, Skeptic or Mentor, or write your own. It shows in its own conversation and in group chats.
- **Pictures open in the window**: click one you sent to look closer, right away, instead of waiting for Preview. Pinch or double-click to zoom, the arrow keys go to the message's other pictures, and Copy (⌘C) puts it on the clipboard.
- **Kuvo Code's own loader**: the prompt mark draws itself in quiet dashes wherever something's loading or working, and the starting screen shows Kuvo Code's icon.
- A bot moves in one place at a time: where it's working in the conversation in view, otherwise in the sidebar.
- Showing or hiding the side panel or the sidebar no longer makes the conversation flicker and jump: it takes its new width at once while the panel slides.
- Sending a message after an undo no longer makes the conversation flicker: the undone part goes and your message appears in one step. A message that starts the agent no longer flashes in the waiting list above the composer.
- Claude models through GitHub Copilot work again: they failed with "thinking.adaptive.block_binding: Extra inputs are not permitted", on this Mac and on machines.
- The side panel no longer shows a blank tab, its bar stuck in the middle, after the window is closed and opened again. Its terminals and pages also keep running while the engine restarts.
- **A browser on your machines**: agents on a remote machine browse with a browser that runs there, so they keep going while your Mac is off, and `localhost` is the machine. In a session on the machine, the side panel's browser tabs are its pages, live: new tabs open there, pages the agent opens show up as tabs, and you can watch or click and type in them yourself, as sharp as your screen, with scrolling that moves at once. Kuvo Code brings Chromium with everything it needs into `~/.kuvo-code` on the machine, so nothing is installed on the system.
- **Using a machine's browser**: right-click a page for a menu to open or copy a link, zoom with ⌘+ and ⌘− or a pinch (zoomed out, a page lays out as wide as on a desktop), and the pointer turns into a hand over links and a text cursor over fields. What a page downloads stays on the machine; **Save to Mac** copies it into your Downloads folder. It asks sites for your Mac's languages. Agents browsing at the same time, like two bots waking at once, each keep to a page of their own, the panel follows only the agent of the conversation you're in, and the badge over a page names the bot browsing it. Pages only agents used close after half a day left alone. Open pages come back when the browser starts again, after an update or a rest.
- A machine's browser stays smoother over a slow connection: a page that moves, like scrolling or an animation, shows up to about twice the frames per second from a far-away server.
- **A new model picker**, as in Codex: it opens on the model's effort, a slider; click the level and the model above it for the model list, and picking one turns back to its effort, without closing in between. More models lists them all, typing searches them, and the session takes your choice once, when the picker closes. The note in the conversation names the effort too.
- A bot's conversation has just its name at the top; its avatar shows where it lives.
- Two Macs on one machine no longer take turns restarting its engine: the second uses the one that's running.
- The panel's browser handles files: a page's upload button opens the file picker, and downloads go to your Downloads folder, with a bar that shows their progress and **Show in Finder**.
- The panel's browser shows a page's alerts, confirmations and questions in a bar over it. Before, they were skipped, and a confirmation always answered no.
- A step that brings back a picture, like the agent's screenshot of a page, shows it when you open the step; click it to look closer.
- **See where the agent acts**: when it browses, a pointer glides to what it clicks, pulses as it clicks, and rings the field it types into, in your Mac's browser and in a machine's. In the conversation, each browser step has an icon for what it does.
- Agents can list, switch and close browser tabs, attach files to a page's upload, find what they download, accept a page's confirmation when it should go ahead, hover over menus, and wait for a text to show on a page.
- A bot that wakes up, or a conversation's first message in a folder just opened, waits a moment for its tools, so the agent has its browser from the first step.
- In Edit Bot, **Wake Up Now** sends a waiting wake-up right away, to see the bot's job run, and **Pause Wake-Ups** holds them all until you turn it off; the sidebar says Paused meanwhile.
- A bot on this Mac browses in tabs of its own, so one waking up never takes over the page you're on. Its tabs show in the side panel next to yours while you're in its conversation, or a group chat it's in.
- **Wake-ups that repeat**: a bot schedules a recurring job once, like every morning at 9, every 2 hours or on weekdays, and it keeps coming back at the same time of day, across daylight saving changes too, until it's canceled. Before, a bot rescheduled itself after every run, and a run that failed ended the job. Edit Bot shows how often each one repeats.
- In Edit Bot, **Add Wake-Up…** schedules one yourself: pick when, how often it repeats and what the bot does then, without asking it in its conversation.
- **Watches for bots**: to keep an eye on something (a status page, a build, a price), a bot can set a watch: Kuvo Code runs a quick check for it on a schedule, without its model, and wakes it only when what the check shows changes, with what it shows now. Cheaper than waking up every hour just to look. Edit Bot lists them, with Check Now to see what a check shows, the sidebar says Watching, and the bot keeps a lookout, glancing one way and the other.
- **Share a bot**: Edit Bot's **Export…** saves a file with its look, job, instructions and personality (not its memory or wake-ups); opening one (or **File › Import Bot…**) starts a new bot from it, as a template does.
- Ask the agent how to do something in Kuvo Code: it knows where the docs are, and reads the page that covers it rather than guessing.
- **Reply to a message, or part of one**: the reply arrow under an answer (or under a bot's message in a group chat) puts what you selected in it, or all of it, in a Replying To card over the composer; your message goes with the quote above it. In a group chat it names the bot too.
- **Reply from a notification**: when a session or a bot finishes while you're in another app, its notification's **Reply** sends your answer straight to the conversation, like a chat app, without switching to Kuvo Code.
- A bot on a machine that finished while your Mac was asleep or offline tells you once the Mac is back, in a notification like any other, rather than not at all.
- When an agent or a bot asks you a question while you're in another app, the notification shows the question itself, with its choices as buttons (and a field to answer in your own words), so you can answer without switching.
- A bot with news you haven't read shows the start of what it said under its name in the sidebar, as a chat list does.
- **Take Over**: while an agent browses, the badge over the page has Take Over, in your Mac's browser and a machine's. The page is yours until you click Hand Back; the agent's browser steps wait meanwhile, then it's told you were there and sees the page as you left it. The panel's browser on your Mac now shows that badge too, naming the bot that's browsing.
- **Group chats that meet on their own**: in a group chat's editor, turn on Meets on a Schedule, pick a time, how often (every day, on weekdays, every week) and what to go over. At that time the topic goes to the chat and the bots talk it through; while you're away, a notification brings the lead's sum-up, and Reply answers in the chat.
- While an agent or a bot works on this Mac, the Mac doesn't go to sleep on its own, so a long task isn't cut off when you step away; the display can still sleep. Turn it off in Settings › General.
- A bot on a machine whose clock is in another time zone than yours wakes up at the times you mean, in your time zone, its repeats and weekends too.
- When a session or a bot finishes while you're in another app, the notification shows the start of its reply, not just "Finished", and a bot's carries its name.
- **Start a bot from a ready-made one**: New Bot offers bots to begin with, like a morning news digest, a page watcher, a price tracker, a researcher, a build keeper and a morning standup, each with a job, instructions and a look to change as you like. A new bot's conversation offers **Start Its Job**, which sets it going: it asks for what it needs and schedules its next run.
- For a site you choose, agents can sign in on their own with its saved password: tick **Let agents sign in here on their own** in the sign-in card. It still goes straight into the page, you get a notification, and **Settings › Passwords** lists those sites to turn off.
- **Agents can sign in for you**: when a page wants a sign-in, the agent asks in its conversation, like a permission request. Type your username and password there (or pick a saved one) and they go straight into the page, in your Mac's browser or a machine's; the agent and the model never see them, and they're blanked out of what the agent reads and its screenshots. It asks the same way for a two-step code, and for a step only you can do, like approving the sign-in on your phone. The conversation shows the hand in the sidebar until you answer.
- After your Mac wakes, a machine that lost its connection while it slept connects again by itself.
- A machine whose connection stopped working without closing (its engine restarted behind it, say) is noticed within seconds and connected again by itself, and it keeps trying for half an hour. Meanwhile a bar over the composer says so, with **Connect Now**, and sending waits, rather than failing with an error.
- **Integrations**: let the agent and your bots work with your mail, calendars, chats, socials and code tools, in **Settings › Integrations**. Each connects the best way it has: its maker's own server where you sign in once (Fastmail, GitLab, Linear, Notion, Jira, Calendly), with a token or app of yours (GitHub, Slack, Gmail, Google Calendar, Asana, Zoom), through an open-source server with a key you bring (Outlook, Apple Calendar and Reminders, CalDAV calendars, Todoist, Figma), or on its site in the panel's browser (Discord, Telegram, WhatsApp, X, LinkedIn, Reddit, Bluesky, Mastodon). Keys stay in your Keychain.
- Outlook's sign-in reaches your machines too: sign in with its code once, on this Mac or a machine, and both have it.
- Integrations you sign in to, like Notion or Linear, work on your machines too: the sign-in is copied to each machine's engine and kept in step, so a bot there uses Notion's own tools instead of opening its website. Ask about a connected service and the agent reaches for its tools first. **Remove** now signs you out properly, here and on your machines.
- Bots, the loader and the shimmer on "Working…" move without costing you battery: their motion is now played by the system's animation engine on the GPU, so Kuvo Code at rest with bots in the sidebar uses next to no CPU, where it used about a third of a core, and a session at work no longer pays for its spinners and shimmers (three took a tenth of a core, even with the window hidden).
- Your bots, group chats and personalities are safe from a file that won't read: it's set aside next to itself as `.unreadable.json` instead of being written over with an empty list.
- A machine's browser has the same toolbar as this Mac's: its More menu now zooms and opens Browser Settings too.
- Copy Path copies the whole path everywhere; in Changes, Copy Relative Path gives it from the project, and a step that touched a file can copy its path too.
- Escape closes a custom provider's settings, as it does an agent's, a command's or an MCP server's.
- Shift-Return starts a new line where the cursor is, not at the end of what you've written, in sessions and group chats.
- Group chats quote as sessions do: each part you reply to goes over the composer with a line for your answer, and one message can answer several. Opening a group chat with a draft puts the cursor after it, instead of selecting it.
- Group chats scroll as sessions do, with the button back to the newest message when you scroll up; and sending in a session takes you back to the end, as in a group chat.
- Long conversations can be read from the start: scrolling to the top reads the messages before, 200 at a time, and keeps your place. Before, only the latest 200 showed. Find offers **Search Earlier**, to look through all of it.
- Long conversations stay smooth while the agent writes: only the reply being written is drawn again, not every message before it.
- A conversation no longer opens blank until you show or hide the side panel: when its rows turned out shorter than first guessed, it could stay scrolled past its end.
- Answering many quotes at once no longer fills the window: past a few, they scroll above the message field, with the one you're answering in view, and **Remove All** clears them.
- **Accounts** opens in Settings, from the sidebar's menu or ⇧⌘K, instead of a sheet of its own.
- Signing in to an integration ends on a sheet that fits what it says, with the service's own name and what you can do now.
- New bots to start from: **Compass** plans your day from your calendar and mail, **Courier** keeps up with your inbox and drafts replies, and **Echo** keeps up with your mentions on social sites. They use your integrations, or the browser without them, and never send anything without asking.
- On your machines, the engine and what it runs keep their temporary files in `~/.kuvo-code` rather than `/tmp`, and on this Mac in Kuvo Code's own temporary folder.
- Long conversations scroll more smoothly: the transcript isn't worked out again as you scroll, and short messages skip the measuring and masking only long ones need. A whole history opening at once no longer fades in row by row.
- Kuvo Code uses much less power at rest: bots' animations pause while its window can't be seen, and a resting bot moves with fewer frames.
- The agent's steps between its replies are summed up in a line, like "Ran 6 commands, read 3 files", that opens to each; the step under way still shows while it works. Settings › Appearance › Agent's steps shows each step again, or only how many there were.
- Replying to several parts at once: select text in the conversation and choose **Add to Chat** (or **Copy**) in the menu over it, as many times as you like. Each part goes over the composer with a line for your answer, and your message shows each quote with its answer. The reply arrow under a reply quotes all of it.
- Ask the agent to show you a file or folder, and it opens it in the side panel: a folder in Files, open down to it, a file in a tab of its own. It works on your machines too.
- Expanding the side panel is one smooth motion: the panel widens over the conversation, rather than the two fading through each other, and collapsing it brings the conversation back just as it was.
- When something in a session doesn't work (a message that didn't go, an undo), it says so in a bar over the composer, rather than an alert you have to click away.
- The agent's questions have a new card: one question at a time (‹ 1 of 3 ›), its choices numbered (press a number to pick one, and a choice goes on to the next question), a line to write your own answer, **Skip**, and **×** to dismiss them all. A long one scrolls inside the card, so the window no longer stretches and the composer stays in view.
- A remote machine's sessions stay in the sidebar, and keep their conversations on screen, while the machine reconnects or connects at launch, so you can read them meanwhile. The bar over the composer says whether it's connecting, reconnecting or couldn't, and things that need the machine, like Undo, wait for it.

## 0.4.0

- **A new Settings**, in the main window in place of your sessions: ⌘, opens it, and the back arrow or Esc returns to where you were. Its pages are in groups in a sidebar, with a search field, each in a card under its title. New pages: Appearance, Notifications, Keyboard Shortcuts, Privacy, Storage, Git, Worktrees, Archived Sessions, Browser and Passwords.
- **Appearance**: pick an accent color (macOS's own, one of its colors, or any color), a frosted or solid window, and the conversation's text size and typeface, with a live preview.
- **Storage** shows what Kuvo Code keeps on your Mac, by kind, and cleans up sessions you haven't used in a while, logs, and the engine download kept for machines.
- **Passwords in the panel's browser**: it offers to save a password when you sign in to a site, in your login keychain, and fills it in when you click the key in its toolbar. It never fills one in on its own, and the agent never sees them. Settings › Passwords shows, copies or deletes them.
- **Archived Sessions** brings archived sessions back or deletes them. **Worktrees** lists sessions' worktrees with their size. **Git** sets what sessions' branches start with, and instructions for the commit messages and pull requests Kuvo Code writes. **Browser** lists the sites that keep data in the panel's browser, to remove one at a time.
- Code and text files can open in the editor you choose, in Settings › General. Notifications can go without a sound, and the Dock count has its own switch.
- **Run a command yourself**: start a message with `!`, like `!npm test`, to run it in the session's folder (on the server, for a project on a remote machine). The composer switches to a shell look while you type it, and the command shows in the conversation with its output, which the agent sees with your next message.
- The welcome screen shows Kuvo Code's own icon.
- **The row at the bottom of the sidebar opens a menu**: your accounts, how much your plans have left and when they reset, your machines and how they're connected, Settings, and Help, with the docs, what's new and a way to report an issue. The Help menu has the same links.
- **Remote machines**: open projects on a Linux server you reach with SSH, like a home server or a VPS, next to your Mac's. Add one in Settings › Machines, or under Location in New Project. Kuvo Code installs its engine there and runs the project's sessions on it; Changes, Files, the terminal and Run work on the machine too. A task carries on while your Mac sleeps or is off, and its work is there when you come back. Your API keys and GitHub Copilot sign-in go along, held in memory, and if the connection drops, Kuvo Code reconnects by itself.

## 0.3.0

- **A livelier look.** Cards have lit edges instead of gray outlines, the window's glass picks up your desktop's color, and your messages, the selected session and the send button are tinted with your accent color. Code sits in one recessed block, and the agent's steps open inline. Dark mode is deeper and cooler, with brighter code colors; in light mode the window's frame is a bright warm ivory whatever your wallpaper.
- Messages fade out under the conversation's header instead of being cut off, and run on under the composer.
- **A quieter composer**: no outline, smaller corners, and its buttons stay in the background until you point at them.
- **Hide the tab bar**, the whole row at the top, with View › Hide Tab Bar (⌥⌘T) or in Settings › General: the cards reach the top of the window, with the sidebar button next to the window's own. Switch sessions from the sidebar or ⌘K.
- **Open With**: the file viewer's Open button has a menu beside it, and the Changes tab's ⋯ menu an Open With submenu, listing the apps that open the file with their icons, the default first, and Other… for any app.
- The side panel's new tab page fits a narrow panel: its tools stack in one column instead of breaking their names.
- **Many tabs in the side panel** stay readable: each keeps its name, and past what fits the row scrolls sideways, fading at the edge with more and keeping the chosen tab in view.
- **New Project and Edit Project** read as one form: the folders are rows of a field like the name, with adding one as its last row, and Run and Worktree Setup are fields of their own.
- The sidebar sits on the window's glass instead of a card of its own, its rows lined up under the window's buttons, and the tabs start where the conversation does.
- **Files a reply names look like files**: an icon and the name in link color, instead of code.
- **Settings**: long tabs open at the top, Accounts fits each provider's name, and clearer labels in Engine and Panel. New agents, commands and servers are named in their sheet, which says why a name can't be used, and Cancel leaves nothing behind. Escape closes every editor, keys and tokens show as dots until you click them, signing in has one set of buttons, and a rejected API key keeps what you typed.
- Fixed: Add Rule in Settings › Permissions set Edit Files to Allow.
- Fixed: switching an MCP server between this Mac and the web could lose its command, and a new web server stayed off.
- Fixed: on a Mac set to Turkey's region, percentages read "%21"; they read "21%" now.
- Fixed: switching sessions from Recents briefly highlighted the other session under its project.
- Fixed: the tabs started far from the project's name, and the branch's hover fill covered the name.
- **You can tell what's clickable.** Buttons, icons, menus and rows light up under the pointer: the icons under messages and replies, Copy on code blocks, the branch name (now with a menu chevron), the Changes tab's menus and file headers, the agent's steps, pick lists, attachments, tabs and more.
- **Code blocks have line numbers.** Copying, whether with Copy or by selecting part of the code, leaves them out.
- **The usage panel follows the accounts you connected in Kuvo Code**: GitHub Copilot, ChatGPT (Codex), OpenCode, OpenRouter and Z.ai. Connecting one turns it on; tools signed in elsewhere on your Mac, like Claude Code, no longer show up. One with no usage to read stays out of the panel, and Customize says why.
- **Clicking a provider's bar in the usage panel** opens its limits, spend and trend in the same style as the bars, instead of the old card.
- **Review** button in the Changes tab: the agent reviews what the tab shows, with /review.
- **Add Screenshot to Message** in the panel's browser attaches what's on the page to your message.
- Click a picture in the conversation to look closer in Quick Look.
- **Bring your Claude Code agents and commands.** Settings › Agents imports the agents in ~/.claude/agents as subagents, with their descriptions and instructions, and Settings › Commands imports the slash commands in ~/.claude/commands.
- **Attempts.** Under Worktree in a new session's composer, pick 2, 3 or 4 sessions to try the same task, each in a worktree of its own, then compare them and keep the best.
- **Search what was said.** The sidebar's search also looks in conversations, and shows the words around each match; clicking one opens the session with Find on it.
- **Switch branches from the title bar.** Click the branch under the project's name for the repository's branches, latest first, or New Branch….
- **Write your own skills** in Settings › Skills: New Skill… takes a name, when the agent should use it, and its instructions. Edit… changes it later.
- **Answer permission requests from the notification.** When the agent asks while you're in another app, the notification has Allow, Always Allow and Deny buttons.
- **Popular MCP servers in one click.** Settings › MCP lists well-known servers, like Linear, Sentry, Notion, Atlassian, Stripe, Supabase, Neon, Context7 and Hugging Face, each from the company behind it. Add one, and sign in if it needs an account.
- **Create Pull Request** from the Changes tab on any branch other than the main one: it pushes the branch and opens the pull request page on GitHub or GitLab, with a title and description the session's model wrote from the branch's changes.
- **This Session** in the Changes tab shows only what the session's agent changed, apart from your own edits and other sessions'.
- Fixed: outside a git repository, the Changes tab listed the agent's edits without their lines.
- **Command palette (⌘K).** Find a session in any project, a file in this one, or something to do, from New Terminal to any Settings tab, with its shortcut. Before you type, it lists your latest sessions.
- **Run your app with one click.** Give a project a run command, like npm run dev, in Edit Project; the play button in the title bar, or ⌘R, runs it in a terminal in the panel, in the session's folder or worktree. Run again to start it over.
- **Worktrees.** Pick Worktree in a new session's composer and the agent works in its own copy of the project, on a branch of its own named after the session, so several sessions can work at once without touching each other's files or yours. The Changes tab shows everything the branch changed, and its branch menu merges the work into your branch or pushes it and opens a pull request. Archiving the session offers to remove the worktree. A setup command in Edit Project runs in each new worktree, to install dependencies or copy files like .env.
- **Since main** in the Changes tab shows everything a branch changed since it left the main branch, committed or not.
- **Open a folder from outside the app.** Drop it on the Dock icon, choose Open With › Kuvo Code in the Finder, or run `open -a "Kuvo Code" <folder>`, and it opens as a project with a new session. Right-click the Dock icon for your latest sessions and New Session.
- **The engine is opencode 2.0.29.** A reply that runs past the model's length limit now carries on by itself, and the transcript says so in a line.
- **Anonymous usage.** Kuvo Code now shares which features get used and how often, with the app and macOS versions, so work goes where it matters. Never your code, prompts, files or accounts. A note at first launch says so, and you can turn it off there or in Settings › General.

## 0.2.0

- **Set up the agent in Settings.** New Agents, Permissions, MCP, Skills and Commands tabs, and more under Engine, cover what opencode's settings file does: your own agents and their instructions, what the agent may do without asking, MCP servers with their status, slash commands, web search, summaries and more. Changes apply right away.
- **Add your own providers** in Accounts: a company proxy, a self-hosted server or any service with an OpenAI- or Anthropic-compatible API, with its models.
- **Add skills from popular collections on GitHub** in Settings › Skills: see what a skill's files are, add it, and turn any skill on or off.
- **A project can have several folders.** New Project (⇧⌘N, or + next to Projects) names a project and adds its folders; sessions run in the primary one, and the agent can work in the others too and knows them by name. Right-click a project for **Edit Project…** to rename it or add and remove folders.
- The **Files** panel lists all of a project's folders, and its filter looks in all of them. The **Changes** panel has a folder menu to show each folder's changes, and comments there name the folder.
- **Type / for commands:** /init sets up an AGENTS.md that tells the agent about your project, and /review reviews your changes. The conversation shows the command, not the long prompt behind it.
- **Type @ in the composer to mention a file** from any of the project's folders, picked from a list that starts with the files you changed last and narrows as you type.
- **⌘Return queues a message** until the agent is done. Queued messages go one after another, as many as you like, and a message sent with Return while the agent works still reaches it first, at its next step.
- **Messages waiting for the agent are listed above the composer.** Send one now (the agent stops its current step and takes it), put it back in the composer to edit (or press ↑ in an empty composer), or remove it.
- Stop pauses the queue, and so does a failed run, instead of sending the rest into the same error. **Resume** picks it up again.
- **Undo from any of your messages:** hover over it and click Undo From Here to take back the conversation and the agent's file changes since, with the message back in the composer to edit. Redo brings it all back until you send.
- **New Session From Here**, under one of your messages, starts a new session with the conversation up to it, to try another way while keeping this one.
- **Try Again** under a failed run sends your last message again, in place of the failed attempt.
- **Build It** under an answer in Plan mode switches to Build and has the agent carry the plan out.
- **Summarize Now** in the context ring's popover shrinks a long conversation to a summary, to make room before the context window fills up.
- **Files a reply names open with a click**, in the side panel.
- **Open Quickly (⇧⌘O)** finds a file in the project by name and opens it in the side panel.
- **Add to Message**, when you right-click a selection in a file or a terminal in the side panel, puts those lines (as `@src/app.ts:4-6`) or that output in your message.
- When the agent runs code that calls its tools (Code Mode), the step reads "Ran code" and opens to show the code and what it returned.
- **See what a subagent is doing.** When the agent hands part of the task to a subagent, its step opens to show what it was asked and each step it takes, live, then what it found and the tokens and cost it used.
- **Under each reply, "Edited 3 files"** lists what that turn changed, with lines added and removed, each a click from the panel.
- **Commit from the Changes panel**, and push afterwards if you like: Commit… takes what's staged, or all the changes shown, and the session's model can suggest the message.
- **Stage, unstage or discard a file's changes** from its menu in the Changes panel. Discarding asks first, and a new file goes to the Trash.
- **Notifications:** when a session finishes or needs your answer while you're in another app, you get a notification that opens it, and the Dock icon counts the sessions waiting for you. Settings › General turns them off.
- **Pin sessions** you keep coming back to: they stay at the top of the sidebar.
- **Search sessions** from the top of the sidebar, by title or project.
- **Archive sessions** you're done with: they leave the sidebar's lists, and searching still finds them.
- Right-click a session's tab to rename it.
- **Copy or export a conversation as Markdown** from the session's menu in the sidebar, to share it in an issue or a chat.
- **⌘W closes the session tab**, and ⇧⌘T reopens the last one you closed, where it was. ⇧⌘W closes the window.
- A long message, like a pasted log, shows its first lines in the conversation until you click **Show More**.
- **⌘F finds words in the conversation**, highlighting each message they're in.
- **↑ and ↓ in an empty composer go through the messages you sent**, as in a shell.
- What you type in the composer stays there when you switch to another session, and when you quit the app.
- Copy buttons under each reply and, when you hover, under each of your messages.
- Code blocks show their language and have their own **Copy** button.
- Hovering over one of your messages shows when you sent it.
- Right-click a project and choose **Open In** to open it in your editor, terminal or git app.
- Right-click a step that read or changed a file to open the file in the panel or show it in the Finder.
- ⌘1 to ⌘8 show that session tab, and ⌘9 the last one, as in browsers.
- Escape in the composer stops the agent, as ⌘. does.
- While the agent works, the end of the conversation shows how long it's been at it.
- Scrolled up in a conversation, a button takes you back to the newest message.
- A step you stopped, with Stop or Send Now, shows as stopped instead of as a red error.
- The panel no longer shows scroll bars, which took a strip off its content on Macs set to always show them.
- A long conversation sometimes opened part of the way up instead of at its newest message.

## 0.1.2

- **Signing in with Google, Apple and others works in the panel's browser.** Sign-in windows open in their own tab and close themselves when you're done, back on the site you were signing in to.
- **Click the context ring at the top of a conversation** to see what it measures: how full the model's context window is, what the session has cost, and your plan's limits when the usage item follows that account.
- **The terminal sits right on the panel**, in the panel's own color, with no darker box around it and no scroll bar track.
- Links that open a new window always open in a new tab, as in other browsers, so that setting is gone.
- Searching Accounts for a provider that isn't there says so, with a button to clear the search, instead of showing an empty box.
- Closing the panel's last tab leaves a new tab in its place, instead of an empty panel.
- The panel button at the top right of the window is a plain icon, like the sessions button at the top left, and it's the one place to show and hide the panel.
- A narrow panel with a file open no longer spills over the conversation; the file list next to the file gets narrower instead.
- Files and changed lines in the Changes panel are plain rows, not rounded boxes with notches at the edge.
- The line beside a file's line numbers no longer runs up through the file's header.
- The spinner on a working session's tab no longer flies in from the corner of the window.

## 0.1.1

- **Deleting a session asks first**, since it can't be undone.
- **API keys you paste into the usage panel are kept in your Keychain**, not in a file. Keys saved by 0.1.0 move there on their own.

## 0.1.0

Kuvo Code's first public release: a native Mac harness for coding agents that works with any model, on the opencode engine.

### Highlights

- **Any model.** Sign in with a subscription you already have, add an API key, or start with free models that need no account. Pick the model and effort for each message.
- **Built for the Mac.** SwiftUI and Liquid Glass on macOS 26. Sessions sit under their project in the sidebar, transcripts update live, and edits and commands open to show what they did.
- **Review changes like a pull request.** The Changes tab shows the project's uncommitted changes from git, with unchanged lines folded and pictures shown before and after. Comment on any line, and your comments go to the agent with your next message.
- **Files, terminals and a browser.** The side panel holds them as tabs: the project's files with code highlighted and Markdown rendered, your shell in the project folder, and a web browser. A new tab offers the tools and the sites you visit most, and Settings › Panel sets it up the way you like.
- **Browsing for the agent, with any model.** The agent can open pages in the panel's browser, read them, click, type and scroll, and you see every step.
- **Attach anything.** Drop, paste or pick files of any kind. Pictures show up in the transcript.
- **Plans and spend in the menu bar.** One bar per provider shows the limit closest to running out; click it for pace, reset times and spend for today and the last 30 days. Covers Claude, Codex, Copilot, Cursor, OpenCode, OpenRouter, Z.ai and more.
- **Build and Plan modes.** Plan mode talks a change through before making it. With **Ask First**, the agent asks before it edits files or runs commands.
- **Updates itself.** Kuvo Code checks for signed updates once a day and shows what's new before it installs one. **Kuvo Code › Check for Updates…** checks right away.
- **Kept apart from your own opencode.** The engine is the official opencode, unmodified, with its sessions, accounts and settings in Kuvo Code's own folder.
