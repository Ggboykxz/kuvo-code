// The settings: the Mac app's pages, edited the same way — values in, changes into the
// engine's settings file, saved whole as they are made.

import { useEffect, useRef, useState } from "react";
import { useDialogFocus } from "./focus";
import { Symbol } from "./components/symbols";
import { api } from "./api";
import { bootConfig, render, state, useStore } from "./store";
import { PAGES, PAGE_GROUPS, PAGE_SUBTITLES, PAGE_SYMBOLS } from "./SettingsShared";
import {
  AppearancePage,
  GeneralPage,
  KeyboardPage,
  ProjectsPage,
  ProvidersPage,
  UsagePage,
  GitPage,
  NotificationsPage,
  PrivacyPage,
  PanelPage,
} from "./SettingsPages";
import {
  WorktreesPage,
  StoragePage,
  IntegrationsPage,
  BrowserPage,
  PasswordsPage,
  PhonePage,
  AutoPage,
  MachinesPage,
  AccountsPage,
  BotsPage,
  ArchivedPage,
  PermissionsPage,
  SystemPage,
} from "./SettingsPagesExtra";
import { McpPage } from "./SettingsMcp";
import {
  AgentsPage,
  SkillsPage,
  CommandsPage,
} from "./SettingsAgents";

export { PAGES, PAGE_GROUPS, PAGE_SUBTITLES, PAGE_SYMBOLS } from "./SettingsShared";

export const settingsPageTitle = (section: string) =>
  PAGES.find(([id]) => id === section)?.[1] ?? "Settings";

export function Settings() {
  useStore();
  const [savedPermissions, setSavedPermissions] = useState<{ id: string; action?: string; resource?: string }[]>([]);
  const [system, setSystem] = useState<{ engine?: string; storage?: string; lists?: string }>({});
  const [search, setSearch] = useState("");
  const modalRef = useRef<HTMLDivElement>(null);
  useDialogFocus(state.settingsOpen, modalRef, "#settings-search", "#settings-open");

  useEffect(() => {
    void bootConfig();
    void api<{ permissions: { id: string; action?: string; resource?: string }[] }>("/api/permission/saved")
      .then(answer => setSavedPermissions(answer.permissions ?? []))
      .catch(() => setSavedPermissions([]));
    void api<{ engine?: { status: string; version?: string }; storage?: { log?: number; attachments?: number }; lists?: Record<string, unknown> }>("/api/state")
      .then(answer => setSystem({
        engine: answer.engine ? `${answer.engine.status}${answer.engine.version ? ` · ${answer.engine.version}` : ""}` : undefined,
        storage: answer.storage ? `${answer.storage.log ?? 0} log lines · ${answer.storage.attachments ?? 0} attachments` : undefined,
        lists: answer.lists
          ? Object.entries(answer.lists).map(([key, value]) => `${key}: ${Array.isArray(value) ? value.length : typeof value === "object" && value ? Object.keys(value).length : String(value)}`).join(" · ")
          : undefined,
      }))
      .catch(() => {});
  }, []);

  const section = state.settingsSection;
  const needle = search.trim().toLowerCase();
  const visiblePages = PAGES.filter(([, title]) => !needle || title.toLowerCase().includes(needle));
  const title = settingsPageTitle(section);
  const subtitle = PAGE_SUBTITLES[section];
  const page = (id: string) => {
    switch (id) {
      case "appearance": return <AppearancePage />;
      case "general": return <GeneralPage />;
      case "keyboard": return <KeyboardPage />;
      case "mcp": return <McpPage />;
      case "agents": return <AgentsPage />;
      case "bots": return <BotsPage />;
      case "skills": return <SkillsPage />;
      case "commands": return <CommandsPage />;
      case "projects": return <ProjectsPage />;
      case "providers": return <ProvidersPage />;
      case "accounts": return <AccountsPage />;
      case "usage": return <UsagePage />;
      case "git": return <GitPage />;
      case "worktrees": return <WorktreesPage />;
      case "storage": return <StoragePage />;
      case "integrations": return <IntegrationsPage />;
      case "browser": return <BrowserPage />;
      case "passwords": return <PasswordsPage />;
      case "phone": return <PhonePage />;
      case "auto": return <AutoPage />;
      case "machines": return <MachinesPage />;
      case "archived": return <ArchivedPage />;
      case "permissions": return <PermissionsPage permissions={savedPermissions} onChange={setSavedPermissions} />;
      case "notifications": return <NotificationsPage />;
      case "privacy": return <PrivacyPage />;
      case "panel": return <PanelPage />;
      default: return <SystemPage system={system} />;
    }
  };

  return (
    <div
      id="settings-modal"
      ref={modalRef}
      role="dialog"
      aria-modal="true"
      aria-labelledby="settings-heading"
      tabIndex={-1}
      className={`settings ${state.settingsOpen ? "shown" : ""}`}
      hidden={!state.settingsOpen}
    >
      {/* Settings takes the sessions' place, the Mac's way: its sidebar on the glass,
          the open page in a card beside it (SettingsView.swift:24-73). */}
      <aside className="settings-sidebar">
        <div className="settings-heading" id="settings-heading">Settings</div>
        <label className="search-well settings-search">
          <svg viewBox="0 0 16 16" width="12" height="12" fill="none" aria-hidden="true">
            <circle cx="6.9" cy="6.9" r="4" stroke="currentColor" strokeWidth="1.2" />
            <path d="M9.9 9.9l3.2 3.2" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
          </svg>
          <input
            id="settings-search"
            value={search}
            placeholder="Search"
            aria-label="Search settings"
            spellCheck={false}
            onChange={event => setSearch(event.target.value)}
          />
        </label>
        <div className="settings-nav-scroll">
          <nav className="settings-nav" aria-label="Settings sections">
            {PAGE_GROUPS.map(([group, ids]) => {
              const members = visiblePages.filter(([id]) => (ids as readonly string[]).includes(id));
              if (!members.length) return null;
              return (
                <div className="settings-group" key={group}>
                  <div className="settings-group-title">{group}</div>
                  {members.map(([id, name]) => (
                    <button
                      key={id}
                      data-section={id}
                      className={section === id ? "active" : ""}
                      aria-current={section === id ? "page" : undefined}
                      onClick={() => { state.settingsSection = id; render(); }}
                    >
                      <Symbol name={PAGE_SYMBOLS[id] ?? "gearshape"} size={15} />
                      <span>{name}</span>
                    </button>
                  ))}
                </div>
              );
            })}
          </nav>
          {visiblePages.length === 0 ? <div className="settings-no-results">No Results</div> : null}
        </div>
      </aside>
      <section className="settings-content card">
        <div className="settings-content-head">
          <h1>{title}</h1>
          {subtitle ? <p>{subtitle}</p> : null}
        </div>
        <div className="settings-pages">
          {PAGES.map(([id]) => (
            <div className="settings-page" data-section={id} hidden={section !== id} key={id}>{page(id)}</div>
          ))}
        </div>
      </section>
    </div>
  );
}
