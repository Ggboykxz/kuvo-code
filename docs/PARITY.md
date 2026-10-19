# Parity — the Mac app, and the Windows one

What the macOS app does (646 Swift files, ~133 000 lines) and where the Windows client
stands. The Windows app is not a translation of the Swift *code* — it is the same
**behaviour**, written again in React and TypeScript on top of the same engine
(`windows/app` for the view, `windows/harness` for the server, `OpenCodeKit`'s routes
mirrored in `windows/harness/engine.mjs` and typed in `windows/app/src/api.ts`).

**Legend** — ✅ porté · ◐ partiel · ⬜ à faire · ⛔ hors périmètre (décidé ou amont)

## The conversation

| Mac | Windows |
| --- | --- |
| `SessionView`, `TranscriptView` | ✅ la vue React (`App.tsx`), même lecture des événements |
| `Composer` | ✅ envoi, pièces jointes, glisser-déposer, files d'un coup |
| `ComposerMenus` | ✅ (modèles et agents en menus cherchables, groupés par fournisseur) |
| `ModelPicker` | ✅ sélecteur de modèle (par fournisseur) |
| `QueueDock` | ✅ la file (steer/queue, reprendre), avec repli |
| `ContextGauge` | ✅ la jauge + son popover (fenêtre de contexte, coût, compact) |
| `StepsRow` | ✅ (le résumé des étapes, dépliable) |
| `AttentionCards` | ✅ les demandes de permission et les formulaires |
| `YourMessage`, `AttachmentViews` | ✅ (pièces jointes, images) |
| `ToolCallView`, `ShellRow` | ✅ (outils, shell, diff par outil) |
| `DiffView` | ✅ la vue des changements d'un fichier |
| `FindBar` | ✅ (le header) |
| `QuoteList`, `SelectionMenu` | ✅ (sélectionner, *Quote*, la citation part avec le message) |
| `LongText` | ✅ (repliés, *Show more*) |
| `MathText` | ✅ (KaTeX, $inline$ et $$bloc$$, les polices embarquées) |
| `MarkdownChunks` | ✅ (marked, assaini) |
| `CodeTextView` | ✅ (copie, surlignage) |
| `FileLinks` | ◐ les liens de fichiers (la recherche de fichiers existe) |
| `WidgetView` | ⛔ c'est la fonction du navigateur intégré (`kuvo-browser_show_widget`), rendue en WebView : elle suit le navigateur |
| `ConversationScroll` | ✅ (la conversation suit le bas ; *↓ Latest* quand on relit) |

## The side panel and the window

| Mac | Windows |
| --- | --- |
| `SidebarView` | ✅ sessions, recherche, non lus, archivage |
| `UtilitiesPane` / `FilesView` | ✅ l'onglet Files |
| `TerminalSession` | ✅ l'onglet Terminal (ConPTY du shell) |
| `ChangesPanel` | ✅ l'onglet Changes : git, plis, notes de ligne, message écrit, commit |
| `ProjectChanges` | ✅ les portées uncommitted / unstaged / staged / branch / session |
| `TitleBar`, `RootView`, `MainView` | ✅ la coque, la bande de titre |
| `CommandPalette` | ✅ (Ctrl+K) — il reste la recherche de fichiers à y ajouter |
| `OpenQuickly` | ✅ (la palette trouve les fichiers) |
| `BrowserSession`, `BrowserChrome`, `BrowserAskCard` | ⛔ le navigateur intégré : surface **amont** |
| `ImageViewer` | ✅ (la visionneuse par-dessus la page) |
| `AgentBadge` | ⬜ |

## The settings

| Mac | Windows |
| --- | --- |
| `GeneralSettings` | ✅ (mises à jour, démarrage à l'login, veille, import opencode) |
| `AppearanceSettings` | ✅ (accent, thème, taille du texte, mouvement) |
| `ShortcutsSettings` | ✅ la liste, cherchable ; les raccourcis sont câblés |
| `MCPSettings` | ✅ (état, édition, catalogue, timeouts, import opencode) |
| `AgentsSettings` | ✅ (défaut, mode, modèle, pas, instructions, règles) |
| `SkillsSettings` | ✅ (liste, on/off, SKILL.md) |
| `CommandsSettings` | ✅ (les vôtres + celles du moteur) |
| `PermissionsSettings` | ✅ (règles enregistrées, oubli) |
| `ArchivedSessionsSettings` | ✅ |
| `GitSettings` | ✅ (préfixe de branche, instructions de commit et de PR) |
| `EngineSettings`, `StorageSettings` | ✅ |
| `SettingsDetail`, `SettingsControls` | ✅ (les éditeurs, en pages) |
| `IntegrationsSettings` | ⛔ les sign-ins OAuth : **les secrets** (décidé) |
| `PasswordsSettings` | ⛔ idem |
| `BrowserSettings` | ⛔ navigateur intégré : amont |
| `MachinesSettings`, `MachineForm`, `MachineStatusViews` | ⛔ machines distantes : amont |
| `PhoneSettings`, `PhoneLink` | ⛔ téléphone : amont |
| `SiteSignInPage`, `SiteSignIns` | ⛔ comptes du site : amont |
| `ProvidersView`, `CustomProviders`, `ConnectView` | ⬜ les fournisseurs sur mesure |
| `BotEditor`, `GroupEditor`, `GroupChatView` | ⛔ groupes et bots : amont |

## The rest of the app

| Mac | Windows |
| --- | --- |
| `Workspace`, `SessionModel` | ✅ le moteur, les sessions, les événements |
| `EngineConfig` | ✅ le fichier de réglages, lu et écrit comme le Mac |
| `OpencodeImport` | ✅ (MCP, agents, commandes, modèle — **les clés restent**) |
| `MCPCatalog` | ✅ le catalogue des 11 serveurs populaires |
| `SlashCommands`, `Mentions` | ✅ (/ et @) |
| `ConversationExport` | ✅ (Markdown) |
| `ProjectFiles`, `ProjectFolders` | ✅ (l'arbre, le sélecteur de dossier) |
| `GitBranches` | ✅ (la portée branch) |
| `ReviewComments` | ✅ (les notes de ligne du panneau Changes) |
| `ProjectChanges` (revert) | ✅ (remettre un fichier comme il était) |
| Create Pull Request | ✅ (pousse la branche, le modèle écrit le titre et la description, la page de l'hôte s'ouvre) |
| `Attachments`, `Drafts`, `Quoting` | ◐ |
| `Updates`, `Awake`, `Notifier` | ✅ (via les réglages de la coquille) |
| `Analytics` | ✅ (l'avis, rien n'est collecté) |
| `PagePrinter`, `ImageViewer` | ⬜ / ◐ |
| `UsageAccounts`, `Personalities`, `ProviderCompatibility` | ⬜ |
| `ClaudeCode`, `Bots`, `BotGroups`, `BotRecipe` | ⛔ amont |

## What the shipped Mac app does now (v0.5.20, v0.5.21)

The upstream releases after ours carry behaviours we read in the release notes and ported
or noted:

| Upstream | Here |
| --- | --- |
| v0.5.21 — the sidebar and the side panel slide ahead of the conversation, which moves along | ◐ the panel slides; the sidebar now folds away (Ctrl+0) and the conversation moves with it |
| v0.5.21 — opening or closing them no longer leaves the conversation blank | ✅ (the layout reflows) |
| v0.5.21 — the agent's commands find *your* sign-ins and settings, as in a terminal | ⛔ not ours to fix: it needs the engine to hand the commands the user's environment, while it reads its settings from this app's own folder. Measured: pointing the engine at the user's config home makes it lose this app's skills. |
| v0.5.20 — a reply's lines no longer overlap after the sidebar opens or closes | ✅ (the transcript is fluid) |
| v0.5.20 — the sidebar slides in, kept ready while hidden | ✅ (it folds, with the motion layer's timing) |
| v0.5.20 — picking another model mid-run hands the run over at once | ✅ (the model is posted live) |
| v0.5.20 — a reply that stops arriving says it is waiting for the model | ⬜ engine-side |

## The design

The view is bound to **OpenDesign's design direction `modern-minimal`** ("Modern minimal —
Linear / Vercel"), read with OpenDesign's own tool (`od tools directions --id
modern-minimal --json`); the binding is written down in `windows/harness/ui/DESIGN.md`.
The motion layer is the direction's own, with the Mac's spring kept for the palette.
The contrast of every text/surface pair passes AA in both themes.
