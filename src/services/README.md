# Services

All business logic lives here. Route handlers, server actions, and UI
components are thin wrappers that call services.

Pattern for every method:

    validate → execute → audit

Never put business logic directly in route handlers, server actions, or
UI components.
