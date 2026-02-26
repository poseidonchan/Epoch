# Flower Collection App Design

**Status:** Approved
**Goal:** Build a standalone iOS app that lets users catalog plants/flowers and track recurring care tasks (watering/fertilizing) with local reminders.

## 1. Decision Summary
- Standalone iOS target (new app module), not embedded in `LabOSApp`.
- iOS 17+ minimum.
- Local-only storage and reminders in v1.
- Flower entry uses manual form inputs plus optional photo pick or camera.
- Core v1 care fields are limited to reminder needs to keep scope tight.

## 2. Approved Architecture
- Add a new application target: `FlowerGardenApp` (or equivalent) using SwiftUI.
- Data persistence via **SwiftData**.
- Schedule local reminders with `UNUserNotificationCenter`.
- Keep all functionality in app-local packages/services; no Hub/REST integration.

### Suggested structure
- `Sources/FlowerGardenApp/App/` – app entrypoint, permissions bootstrap, scene setup.
- `Sources/FlowerGardenApp/Core/` – models, store, services, error types.
- `Sources/FlowerGardenApp/Views/` – screens and reusable components.
- `Sources/FlowerGardenApp/Resources/` – localized strings/assets as needed.

### Data model (v1)
- `Flower`
  - `id: UUID`
  - `name: String`
  - `species: String?`
  - `notes: String`
  - `zone: String?`
  - `isIndoor: Bool`
  - `wateringIntervalDays: Int`
  - `fertilizingIntervalDays: Int`
  - `lastWateredAt: Date?`
  - `lastFertilizedAt: Date?`
  - `photoFileNames: [String]`
  - `createdAt`, `updatedAt`

- `CareTaskRecord`
  - `id: UUID`
  - `flowerID: UUID`
  - `kind: CareType` (`watering` / `fertilizing`)
  - `intervalDays: Int`
  - `lastCompletedAt: Date?`
  - `nextDueAt: Date`
  - `isCompleted: Bool`

- `FlowerPhoto` entries are optional in v1; metadata is stored as lightweight filename references to avoid model bloat.

### Data flow
- `FlowerGardenStore` owns `ModelContext` and exposes CRUD + computed care calculations.
- On create/update, store computes `nextDueAt` for both care types.
- `ReminderService` observes changes and updates/removes future notification requests.
- All user actions (`Watered`, `Fertilized`, edit flower) are reflected immediately in state and persisted transactionally.

## 3. Approach Options
1. **Recommended: new standalone SwiftUI+SwiftData target**
   - Fast, isolated scope; clear boundary from existing LabOS app behavior.
2. **Feature module inside existing LabOS app**
   - Reuses existing shell but introduces coupling and broader regression risk.
3. **Web-first then native port**
   - Quicker visual exploration, slower path to iOS-native camera/reminders and native persistence behavior.

## 4. UI/UX (MVP)
- **Home**: next-due cards + quick summary of overdue tasks.
- **Flowers**: searchable list/filter and add/edit actions.
- **Add/Edit Flower**: name, species, care intervals, optional photo attachment.
- **Flower Detail**: history, last care dates, quick mark buttons.
- **Settings**: notification permission status, default reminder hour, data-wipe option.

## 5. Error handling and edge cases
- Notification denied: app remains usable; actions disabled with clear settings guidance.
- Save failures: preserve draft in transient UI state and present retry.
- Duplicate reminder collision: cancel by identifier prefix and dedupe before scheduling.
- Photo load failures: save flower without media and display placeholder.
- Invalid intervals (0/negative): validation at edit time, plus guard in model logic.

## 6. QA and testing
- Unit tests:
  - due-date calculation
  - overdue detection
  - schedule recomputation after action completion
  - invalid interval guard
- Service tests:
  - `ReminderService` request creation/update/removal using protocol-abstractions.
- Manual QA matrix:
  - Add/edit with/without photos
  - Watered/Fertilized action updates next due
  - permission denied/re-enabled behavior
  - restart app and validate persistence

## 7. Delivery phases
1. Target setup + persistence schema scaffold.
2. Flower list/detail/edit flows.
3. Reminder scheduling service + permissions.
4. Testing + polish (empty states, search/filter, cleanup UX).
