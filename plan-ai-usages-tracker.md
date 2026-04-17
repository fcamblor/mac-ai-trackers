# Plan — AI Usages Tracker (`usages.json` + connecteurs)

## Couche 1 — Structure générale

### 1. Nouveau format `~/.cache/ai-usages-tracker/usages.json`

Un fichier JSON unique, multi-vendor, multi-account. Chaque entrée
porte un `vendor` ("claude", "codex", "gh-copilot"…) et un `account`
(ex : email). Les métriques sont un tableau typé :

- **time-window** : `name`, `type:"time-window"`, `resetAt` (ISO),
  `windowDurationMinutes`, `usagePercent`
- **pay-as-you-go** : `name`, `type:"pay-as-you-go"`, `currentAmount`,
  `currency`

Métadonnées par entrée : `lastAcquiredOn`, `lastError`, `isActive`.

### 2. Architecture Connecteur

Un protocole `UsageConnector` (Swift) définit :
- `vendor: String`
- `func fetchUsages() async throws -> [AccountUsage]`
- `func resolveActiveAccount() -> String?`

Chaque vendor = 1 implémentation concrète. Seul
`ClaudeCodeConnector` est implémenté dans un premier temps.

### 3. ClaudeCodeConnector — sources de données

- **Token OAuth** : lu depuis le Keychain macOS
  (`Claude Code-credentials` → `claudeAiOauth.accessToken`)
- **API** : `GET https://api.anthropic.com/api/oauth/usage`
  avec header `anthropic-beta: oauth-2025-04-20`
- **Account actif** : lu depuis `~/.claude.json`
  → `.oauthAccount.emailAddress`
- Produit 2 métriques time-window (`session`, `weekly`) ;
  pourrait aussi produire `sonnet` ou `pay-as-you-go` si l'API
  les expose à terme.

### 4. Scheduler (tâche de fond)

Un composant `UsagePoller` orchestre les connecteurs enregistrés.
- Fréquence paramétrable (défaut 3 min), configurable au lancement.
- Écrit le résultat agrégé dans `~/.cache/ai-usages-tracker/usages.json`
  avec lock file pour éviter les écritures concurrentes.
- Tourne dans un `Task` Swift détaché, compatible avec le run-loop
  SwiftUI de la menubar app.

### 5. Intégration dans l'app menubar

L'app existante (`AIUsagesTrackersApp`) démarre le poller au
lancement. La menubar affichera à terme les métriques, mais le scope
de ce plan est le **data layer** (connecteur + fichier JSON), pas
l'UI.

---

### Risques architecturaux

| Risque | Impact | Mitigation |
|--------|--------|------------|
| Token OAuth expiré / absent | Pas de données | Fallback sur cache + `lastError` dans le JSON |
| Accès Keychain bloqué (permissions) | Crash ou silence | Gérer l'erreur Keychain explicitement, journaliser |
| Écriture concurrente sur usages.json | Corruption | Lock file atomique (même approche que ccstatusline) |
| Format API Anthropic change | Métriques cassées | Parser résilient, erreur typée dans `lastError` |
