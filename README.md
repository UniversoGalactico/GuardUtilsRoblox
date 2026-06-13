# GuardUtils – Reusable Validation, Sanitization & Rate Limiting Module
# Módulo Reutilizable de Validación, Sanitización y Rate Limiting

🌐 **English** | **Español**

---

## 🇬🇧 English

A free, dependency-free utility module for Roblox.  
Provides validation, sanitization and rate limiting functions used by all modules in the Universo ecosystem.

**What it offers:**
- **isValidData** – Recursively validates values for DataStore safety.
- **sanitizeNumber** – Rejects NaN, Infinity, and clamps to a safe range.
- **sanitizeString** – Removes null bytes and limits length.
- **jugadorValido** – Checks if a player is still active in the game.
- **datosCargados** – Generic data load check (requires an external isLoaded function).
- **isRateLimited** – Sliding-window rate limiter for any string key.
- **deepCopy** – Cycle-safe deep copy of tables.
- **isDataStoreSafe** – Checks if a value is safe to write to a DataStore.
- **generarId** – Generates unique IDs for keys or logs.

**How to use:**
1. Place the `ModuleScript` in `ServerScriptService.ServerModules`.
2. Require it: `local GuardUtils = require(script.Parent.GuardUtils)`
3. Use any function directly: `GuardUtils.isValidData(value)`, `GuardUtils.isRateLimited("key")`.

**Links:**
- **Talent Hub:** [More advanced modules](https://create.roblox.com/talent/creators/5075515911)
- **Discord:** universogalactico_28974 (UniversoGalactico)

---

## 🇪🇸 Español

Un módulo de utilidades gratuito y sin dependencias para Roblox.  
Provee funciones de validación, sanitización y rate limiting usadas por todos los módulos del ecosistema Universo.

**Qué ofrece:**
- **isValidData** – Valida recursivamente valores para seguridad en DataStore.
- **sanitizeNumber** – Rechaza NaN, infinitos y ajusta a un rango seguro.
- **sanitizeString** – Elimina bytes nulos y limita la longitud.
- **jugadorValido** – Verifica si un jugador sigue activo en el juego.
- **datosCargados** – Comprobación genérica de carga de datos (requiere una función isLoaded externa).
- **isRateLimited** – Limitador de frecuencia con ventana deslizante para claves string.
- **deepCopy** – Copia profunda de tablas con protección anti‑ciclos.
- **isDataStoreSafe** – Verifica si un valor es seguro para escribir en un DataStore.
- **generarId** – Genera IDs únicos para claves o logs.

**Cómo usarlo:**
1. Coloca el `ModuleScript` en `ServerScriptService.ServerModules`.
2. Requiérelo: `local GuardUtils = require(script.Parent.GuardUtils)`
3. Usa cualquier función directamente: `GuardUtils.isValidData(value)`, `GuardUtils.isRateLimited("clave")`.

**Enlaces:**
- **Talent Hub:** [Módulos avanzados de pago](https://create.roblox.com/talent/creators/5075515911)
- **Discord:** universogalactico_28974 (UniversoGalactico)

---

*Made with ❤️ by Universogalactico64*
