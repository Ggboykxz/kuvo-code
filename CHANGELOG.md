# Changelog

What changed in each release, for people using Kuvo Code. Add changes people would notice under
Unreleased, in plain words about what they'll see, as part of the change itself. Before a
release, Unreleased is renamed to the version; the release notes come from that section.

## Unreleased
- On a machine, only you can open Kuvo Code's folder (`~/.kuvo-code`): where home folders are open to others there, other users could read your conversations, bots' memory and settings in it.
- A message from an agent on a machine names its sender only when that agent is on the machine, and messages from a machine are limited as one sender's: one past the limit goes a while later rather than being lost.
- A file saved to your Mac from a machine's browser is marked as downloaded, so macOS checks it before it opens, as it does any download.
- On a machine, the engine's password no longer appears on a command line while a bot's wake-up is sent (another user there could read it), nor in the environment of a watch's check.
- A page the agent saves as a PDF leaves out what you filled in (a password, a code), as its screenshots do, in the browser on your Mac and on a machine.
- Saved passwords are offered and filled in only over https, where they were saved: a sign-in page over plain http (which can be read on the way) gets no saved password, from you or the agent, on your Mac or in a machine's browser.
- A widget in the conversation sends a message as you only when you click in it, and opens a web address in your browser only from your click: a widget's script could do either on its own.
- Under Ask First, and in a group chat, the agent's browser opens files in the conversation's folder (and temporary ones) only: a file elsewhere on your Mac or the machine, which a command would have asked about, isn't opened without your say, nor read when a link, a redirect or going back leads there (on a machine, a page's pictures and frames from elsewhere don't load either). A tab you opened on such a file stays as it is, and the agent goes on in a new tab.
- On a machine, an agent no longer switches to or closes a browser tab another conversation's agent is using, as on your Mac.
- A page in the panel that isn't on screen (a bot's, say) can no longer open the file picker over the app, where you couldn't tell which page asked.
- On a machine, a page you took over stays yours while your Mac sleeps, its connection drops for a moment or you look at another conversation: the agent doesn't go on in it until you hand it back, or you remove the machine or quit. Another Mac's hand-back no longer ends yours.
- A machine's browser saves a download with a long name in Japanese, Chinese or another such script under its name, and clears downloads after a week while it keeps running too.
- On a machine, a link the agent clicks that opens a new window (a sign-in window, say) is where it goes on, as on your Mac, rather than back on the page that opened it.
- After your Mac wakes, a machine's browser view comes back right away, rather than once its old connection times out.
- Letting agents sign in to a site on their own is for the account you allowed it with, and ends when you delete that password: one saved later isn't used without asking.
- The browser offers to save a password on https pages only, where it fills them in, in the toolbar and in the agent's sign-in card; on http://localhost it offered to save one it could never fill.
- A bot can no longer schedule a wake-up that repeats more than a year apart: one far longer made Kuvo Code quit as it opened, again each time, after sending it.
- A repeating wake-up isn't queued again while the last one still waits (the bot busy, or waiting on you), so a bot doesn't come back to a pile of them.
- Weekday wake-ups and meetings are Monday to Friday wherever you are; in a few places they followed the local weekend.
- A wake-up time written with its time zone (06:00Z, 09:00+03:00) is that moment on your Mac too, not that hour in your own time zone.
- On a machine, a bot's watches no longer hold up its wake-ups, a wake-up isn't sent twice when the engine starts over, wake-ups reach the engine on a machine set up with a web proxy, its times are right on a machine without time zone files, and a repeat like 08m is refused rather than stopping that wake-up for good.
- Removing a machine that can't be reached signs out of your accounts there, stops its engine and deletes integrations' sign-ins the next time it can be, as do deleting one of its bots and removing an integration: before, its bots kept waking on your accounts.
- Removing a machine while it's still connecting stops the connection there and then, rather than letting it finish and copy your accounts over; and a machine whose engine another Mac started is left running for that Mac.
- In a group chat: a message you send while the lead hands out the work keeps the parts from starting on their own, and Stop stops the lead too; a part's report is only what the bot did for it; a part whose message you took back ends rather than working forever; @Sam no longer calls Samantha; a meeting missed while Kuvo Code was closed isn't followed by the next minutes later, and one due at launch waits a moment for bots on machines; and a bot taken out of a chat forgets it.
- Anonymous usage no longer includes a short hash tied to your Codex or Claude account when the menu bar follows one: only which tool.
