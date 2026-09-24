# CLAUDE.md — Flutter Project Rules

This file defines architecture and coding rules for AI-assisted development in this project.

The goal is to ensure clean architecture, scalability, and maintainability while keeping development simple and consistent.

---

# Default Behavior
- Always apply the "ui_ux_flutter" skill when:
- Creating new UI screens
- Designing features
- Improving UX
- Writing Flutter UI code
# Skill: ui_ux_flutter
@include .claude/skills/ui_ux_flutter.md

# 🚨 Domain Context (To Be Defined)

This project will be a Fire Alarm Central System.

Detailed rules for:
- alarm handling
- real-time priorities
- UI behavior under stress
- event processing

will be defined later as the system architecture evolves.

---



# 🧠 General Principles

- Prefer simplicity over overengineering
- Keep code modular and testable
- Avoid business logic inside UI components
- UI should only render state and send user actions
- Always think in terms of feature-based architecture
- Code must be readable before being clever

---

# 🏗️ Architecture

Use a Clean Architecture-inspired structure adapted for Flutter:

.env (credentials)

lib/
features/
feature_name/
presentation/
application/
domain/
data/


## Layers

### Presentation
- UI (screens, widgets)
- Riverpod providers (UI state only)
- No API calls here

### Application
- Use cases / orchestration of business logic

### Domain
- Entities
- Repository interfaces only
- No external dependencies

### Data
- AWS Amplify integrations (Auth, API, Storage)
- Repository implementations
- GraphQL communication (AppSync via Amplify API)

---

# ⚡ State Management

- Use Riverpod as the ONLY state management solution
- No BLoC, GetX, Provider, or other state libraries
- Prefer `AsyncValue` for async operations

Rules:
- UI must never call Amplify or APIs directly
- State must be exposed via providers
- Keep providers close to feature scope

---

# ☁️ AWS Amplify (IMPORTANT)

AWS Amplify is the primary backend integration layer for this project.

It is responsible for:
- Authentication (Cognito)
- GraphQL API (AppSync)
- Subscriptions (real-time via WebSocket)
- Token management (JWT handling)

## Rules

- ALL backend communication must go through Amplify
- Never call AWS SDKs directly outside Amplify
- Never manually manage JWT tokens in UI
- Do NOT implement custom Cognito flows unless required

## Amplify structure in Data Layer

- Auth → Amplify Auth (Cognito)
- API → Amplify API (GraphQL AppSync)
- Subscriptions → Amplify API streams

---

# 🔐 Authentication (Cognito via Amplify)

- Authentication is handled exclusively via AWS Amplify Auth
- Supports Google and Apple login through Cognito federation
- Authentication state must be exposed via Riverpod provider

Rules:
- No token parsing in UI
- No manual session handling in widgets
- Auth logic must be isolated in `/data/auth`

---

# 🌐 API Layer (AppSync via Amplify)

- All GraphQL communication uses Amplify API
- Queries, mutations, and subscriptions go through repositories

Rules:
- No GraphQL queries inside UI
- No direct Amplify calls inside presentation layer
- All API logic must be in data/repository layer

---

# 🔄 Real-time (Subscriptions)

- AppSync subscriptions are handled via Amplify API streams
- Subscriptions must be exposed as Riverpod StreamProviders
- UI listens to providers only

---

# 📁 Folder Rules

- Each feature must be fully isolated
- No shared “god modules”

Shared code:
lib/core/
lib/shared/


### Core includes:
- Amplify configuration
- network helpers
- error handling
- base services

### Shared includes:
- reusable UI components
- utilities
- formatters

---

# 🎨 UI Rules

- UI must be dumb (no business logic)
- Break large widgets into smaller components
- Prefer composition over inheritance
- No direct Amplify or API usage in widgets

---

# 🧪 Code Quality Rules

- Prefer explicit code over magic abstractions
- Keep functions small and single responsibility
- Avoid duplication of business logic
- Avoid deep nesting and over-abstraction

---

# 🚫 Forbidden Patterns

- No Amplify calls in UI layer
- No API calls in widgets
- No global mutable state
- No bypassing repository layer
- No mixing domain/data/presentation layers
- No ad-hoc authentication logic

---

# 🤖 AI (Claude) Behavior Rules

When generating code:

- Follow feature-based architecture strictly
- Always use Riverpod for state management
- Always route backend calls through Amplify (data layer only)
- Never bypass repository pattern
- Prefer simplest maintainable solution over clever code
- If uncertain, default to clean architecture separation

---

# 📌 Goal of this project

Build a scalable Flutter application with:

- AWS Amplify (Cognito Auth + AppSync API)
- GraphQL backend with real-time subscriptions
- Riverpod state management
- Clean feature-based architecture
- Long-term maintainability over speed hacks


---

# 📱 Cross-Platform (Mobile + Web)

This project targets both mobile (iOS/Android) and web (Flutter Web).

All UI and architecture decisions must consider platform differences.

---

## 🧠 Core Principle

- Write UI once, but design it to adapt per platform
- Never assume mobile-only layouts
- Always consider responsiveness and screen size changes
- Web is not just “bigger mobile”

---

## 📐 Layout Rules

- All screens must be responsive by default
- Use flexible layouts (no fixed widths unless necessary)
- Prefer:
  - `LayoutBuilder`
  - `MediaQuery`
  - responsive breakpoints

Rules:
- Avoid hardcoded pixel sizes for layout structure
- Never design screens assuming a single screen size
- Use adaptive spacing for web vs mobile

### 🔄 Both orientations, ALWAYS (non-negotiable)

The central tablet lives in **landscape** most of the time; phones are mostly portrait. Every screen,
sheet, dialog and custom-painted canvas must work in **both** orientations, and "work" means laid out
for that orientation — not merely "does not crash".

- Never assume `height > width`. Read the shape from `LayoutBuilder` / `MediaQuery.orientationOf`
  and adapt — but **keep the same picture in both orientations**: scale, fit, scroll or re-space it;
  do not invent a different layout for landscape (the Rede tree stays vertical in landscape and
  opens zoomed out to fit — it is NOT turned sideways). Re-flowing a screen into a different shape
  is a product decision: ask first.
- Floating controls over a canvas (zoom, clear, FABs) must be placed so they can never overlap each
  other on the shortest landscape viewport; prefer putting secondary actions in a toolbar/strip.
- A bottom sheet in landscape has little height: make it `isScrollControlled`, cap it with
  `MediaQuery.sizeOf(context).height`, and let its content scroll. Never a fixed-height sheet.
- Scrollable everything that can be taller than the shortest supported viewport (~600 px landscape
  tablet, ~360 px landscape phone). Yellow/black overflow stripes in either orientation = bug.
- On rotation, re-check any state tied to geometry (pan/zoom transforms, cached sizes, scroll
  offsets) and reset or re-map it — never leave content off-screen.
- Before handing back UI work, state that you checked both orientations (portrait and landscape,
  phone and tablet widths) — if you could not run it, say so explicitly.

---

## 🖥️ Web-Specific Rules

- Mouse/hover interactions must be supported where relevant
- Avoid relying only on gestures (swipe, long press)
- Navigation must support browser behavior (back/forward)
- Components should handle hover states when needed

---

## 📱 Mobile-Specific Rules

- Touch-first interactions remain default on mobile
- Safe areas must always be respected (`SafeArea`)
- Keyboard behavior must be handled properly (forms, inputs)

---

## 🧭 Navigation Rules (Important)

- Navigation must work in both:
  - mobile stack navigation
  - web URL-based navigation

Rules:
- Avoid tightly coupled navigation logic
- Prefer declarative routing (e.g. go_router recommended)
- Do not hardcode navigation flows inside widgets

---

## 🎨 UI Adaptation Rules

- UI must adapt, not duplicate per platform
- Avoid creating separate mobile/web screens unless absolutely required
- Prefer adaptive widgets instead of platform-specific pages

Examples:
- Tables (web) vs cards (mobile)
- Side navigation (web) vs bottom navigation (mobile)

---

## ⌨️ Input & Interaction Rules

- Web must support keyboard navigation
- Forms must support tab navigation
- Buttons must be accessible via keyboard (Enter/Space)

---

## ⚠️ Forbidden Patterns (Cross-platform)

- No fixed-width layouts that break on web
- No mobile-only gesture assumptions
- No duplicated screens for mobile vs web unless justified
- No ignoring hover states in web UI