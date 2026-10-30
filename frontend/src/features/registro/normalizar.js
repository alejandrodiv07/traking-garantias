// Normalización compartida del asistente de registro (Tarea 15 del plan).
// Espeja en MINÚSCULA la lógica de la base (normalizar_serie, spec §5.1):
// la base sigue siendo la única fuente de verdad; esto solo anticipa
// la busqueda para no enviar basura por la red.

/** Mayúsculas, sin espacios ni guiones; los ceros a la izquierda quedan. */
export function normalizarSerie(s) {
  return String(s ?? "")
    .replace(/[ -]/g, "")
    .toUpperCase();
}

/**
 * 'J-30.589.214-7' → { tipo: 'J', documento: '305892147' }.
 * Acepta la letra de tipo primero (V, E, J, G, P, con o sin guion/punto);
 * sin letra, el tipo queda null y el documento solo dígitos.
 */
export function normalizarDocumento(s) {
  const limpio = String(s ?? "")
    .toUpperCase()
    .replace(/^[VEJGP]\s*[.\-]?/, "")
    .replace(/[^0-9]/g, "");
  const tipo = /^[VEJGP]/.test(String(s ?? "").trim().toUpperCase())
    ? String(s).trim().toUpperCase()[0]
    : null;
  return { tipo, documento: limpio };
}