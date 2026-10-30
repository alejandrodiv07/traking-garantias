# Revisión de diseño — Registro y control de garantía

Registro del producto: herramienta interna seria de taller (Prime Telecom). Cálida y sobria, no “startup”. Se asume ese registro; si es otro, corregir aquí.
Base: lectura del CSS y del JSX (no hubo revisión visual en navegador: requiere sesión con 2FA real).

## Puntuación

| Dimensión | Nota | Un 10 en este producto sería… |
|---|---|---|
| Identidad visual | 6 | Login y Tablero comparten una paleta crema/terracota/tinta (`#faf9f5`, `#d97757`, `#191915`) con semáforo propio; ya tiene punto de vista. Falta que lo tenga TODO el producto. |
| Jerarquía de información | 7 | Tablero ordenado por urgencia con tonos neutro/progreso/resuelto/adverso. Un 10: la fila más urgente se reconoce a 2 metros sin leer. |
| Diseño de interacción | 4 | Un 10: escanear serial → autocompletar equipo → falla → fotos, sin tocar el ratón, con avance claro y sin perder datos. Hoy la lógica existe (borrador, reintento) pero no se ve. |
| Tono del texto | 7 | Mensajes concretos en español (“La falla va de 5 a 2000 caracteres”). Falta unificar tuteo/usted y cerrar los textos de error de red. |
| Consistencia | 3 | Un 10: un solo archivo de tokens. Hoy hay tres sistemas. |
| Accesibilidad | 6 | Etiquetas `htmlFor` y `role="alert"` presentes en el asistente. Un 10: foco visible siempre, contraste AA probado, movimiento reducido (ya hay `prefers-reduced-motion`). |

## AI slop / deuda visual, señalada con precisión

1. **El asistente de 6 pasos y las Revisiones no tienen estilos.** `NuevoRegistro.jsx`, los 6 `Paso*.jsx`, `RevisionForm.jsx` e `HistorialRevisiones.jsx` tienen **0 `className`**. Es la pantalla central del hito 1 y hoy sale con estilos del navegador. Es el mayor hueco.
2. **Tres sistemas de tokens en paralelo:** `index.css` (restos de plantilla Vite: acento morado `#aa3bff`, selector `#social`), `login.css` (`--pt-*`) y `Tablero.css` (`--tg-*`, 1186 líneas). Los dos últimos repiten los mismos colores con otro prefijo.
3. **Tailwind importado** (`@import "tailwindcss"`) pero el código usa clases propias: peso muerto y reglas de reset que pelean con el CSS manual.
4. **Tipografía base 18 px** con `letter-spacing` global; en tablas densas obliga a reducir por componente.
5. **Temas mezclados:** `color-scheme: light dark` y variables oscuras en `index.css`, pero Login y Tablero son solo claros ⇒ en un equipo en modo oscuro quedan mitades inconsistentes.
6. **Enfoque por sombra:** `.tg-input:focus { outline: none }` sustituido por `box-shadow`; en modo de alto contraste de Windows esa sombra desaparece.
7. **Paneles provisionales** (`Panel.jsx`): tres roles con la misma plantilla vacía.

## Direcciones acordadas

- **Asistente:** barra de pasos numerada arriba + una columna; Atrás/Siguiente fijos abajo; el paso con error se marca en la barra; el serial recibe el foco automático (lector de barras).
- **Tema:** claro **y** oscuro completo. Un solo archivo `src/styles/tokens.css` con tokens semánticos (`--superficie`, `--texto`, `--acento`, estados) y su bloque `@media (prefers-color-scheme: dark)` + `[data-tema]` si luego se quiere interruptor. Login, Tablero, asistente y revisiones consumen esos tokens.

## Cambios propuestos al plan (tareas nuevas)

1. **D-1 Tokens únicos.** Crear `styles/tokens.css`; migrar `--pt-*` y `--tg-*` a alias de los nuevos y luego eliminarlos; borrar el CSS de plantilla de `index.css` y `App.css`. Prueba: vitest que lea el CSS y verifique que cada token tiene valor claro y oscuro.
2. **D-2 Estilos del asistente y revisiones** con los tokens: contenedor, barra de pasos, campos, errores en línea, estado “subiendo adjuntos / reintentar”.
3. **D-3 Modo oscuro** de Login y Tablero (contraste AA ≥ 4.5:1 en texto y ≥ 3:1 en bordes de campo y semáforo; el semáforo no depende solo del color: ya lleva punto/etiqueta, mantener).
4. **D-4 Accesibilidad:** foco con `outline` visible (usar `:focus-visible`, y `outline` transparente en lugar de `none` para alto contraste); anunciar el cambio de paso con `aria-live="polite"`; `aria-current="step"` en la barra.
5. **D-5 Quitar Tailwind** si no se usa (medir el bundle antes y después; hoy 525 kB).
6. **D-6 Pruebas visuales:** capturas Playwright claro/oscuro, 1280 px y 768 px, de Login, Tablero, cada paso y Revisiones (usa el modo de prueba local con Supabase de desarrollo).

## Qué queda bien (no tocar)

Paleta cálida, semáforo de estados, el Tablero y su movimiento reducido, mensajes de error concretos.
