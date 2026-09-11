/**
 * Reglas de validación de campos del alta de garantía, en un solo sitio.
 *
 * Cada patrón de aquí es un ESPEJO de un CHECK real de la base (el
 * comentario junto a cada uno dice de cuál migración/tabla viene). Si
 * alguna vez divergen, manda la base -- esto solo existe para avisar ANTES
 * de gastar una petición, no para sustituir la validación del servidor.
 *
 * `\p{L}` / `\p{N}` (Unicode) en vez de `[a-zA-Z0-9]` a propósito: un
 * cliente puede llamarse "José Muñoz" o una razón social puede llevar una
 * "ñ" -- una lista ASCII los habría rechazado.
 */

export const PATRONES = Object.freeze({
  // clientes.documento: CHECK (documento ~ '^[0-9]{5,15}$')
  documento: /^[0-9]{5,15}$/,
  // clientes.telefono: CHECK (telefono IS NULL OR telefono ~ '^[0-9+][0-9]{6,19}$')
  telefono: /^[0-9+][0-9]{6,19}$/,
  // clientes.email: CHECK (email = lower(email) AND email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
  email: /^[^@\s]+@[^@\s]+\.[^@\s]+$/,
  // Nombre / razón social: letras, dígitos, espacios y . , ' & -
  nombre: /^[\p{L}\p{N}\s.,'&-]+$/u,
  // Modelo de equipo: letras, dígitos, espacios y . , - /
  modelo: /^[\p{L}\p{N}\s.,\-/]+$/u,
  // Categoría de producto: letras, espacios y -
  categoria: /^[\p{L}\s-]+$/u,
  // Nº de serie: letras, dígitos y guiones (formato típico XXX-0000-XX)
  numeroSerie: /^[A-Za-z0-9-]+$/,
  // Nº de factura: letras, dígitos, puntos y guiones
  numeroFactura: /^[A-Za-z0-9.-]+$/,
});

/** Texto de ayuda a mostrar bajo cada campo -- lo que el usuario puede
    teclear, no lo que no puede (§ui-ux-pro-max input-helper-text). */
export const AYUDA = Object.freeze({
  nombre: "Letras, números, espacios y . , ' & -",
  documento: "Solo dígitos, de 5 a 15.",
  telefono: "Solo dígitos (puede empezar con +), de 7 a 20 caracteres.",
  email: "Un correo válido, en minúsculas.",
  modelo: "Letras, números, espacios y . , - /",
  categoria: "Letras, espacios y guiones.",
  numeroSerie: "Letras, números y guiones.",
  numeroFactura: "Letras, números, puntos y guiones.",
});

function largo(valor) {
  return String(valor ?? "").trim().length;
}

function cumple(valor, patron) {
  const v = String(valor ?? "").trim();
  return v !== "" && patron.test(v);
}

/** Cada `errorX` devuelve el mensaje a mostrar, o `null` si el valor pasa.
    Los campos opcionales devuelven `null` ante un valor vacío. */

export function errorNombre(valor, { min = 3, max = 160 } = {}) {
  const l = largo(valor);
  if (l === 0) return "Este campo es obligatorio.";
  if (l < min || l > max) return `Escribe de ${min} a ${max} caracteres.`;
  if (!cumple(valor, PATRONES.nombre)) return `Solo se permite: ${AYUDA.nombre}`;
  return null;
}

export function errorDocumento(valor) {
  const soloDigitos = String(valor ?? "").replace(/\D/g, "");
  if (soloDigitos === "") return "Este campo es obligatorio.";
  if (!PATRONES.documento.test(soloDigitos)) return `Solo se permite: ${AYUDA.documento}`;
  return null;
}

export function errorTelefono(valor) {
  const v = String(valor ?? "").trim();
  if (v === "") return null; // opcional
  if (!cumple(v, PATRONES.telefono)) return `Solo se permite: ${AYUDA.telefono}`;
  return null;
}

export function errorEmail(valor) {
  const v = String(valor ?? "").trim();
  if (v === "") return null; // opcional
  if (v !== v.toLowerCase()) return "Escribe el correo en minúsculas.";
  if (!cumple(v, PATRONES.email)) return "Escribe un correo válido, por ejemplo nombre@dominio.com.";
  return null;
}

export function errorModelo(valor) {
  const l = largo(valor);
  if (l === 0) return "Este campo es obligatorio.";
  if (l > 80) return "Máximo 80 caracteres.";
  if (!cumple(valor, PATRONES.modelo)) return `Solo se permite: ${AYUDA.modelo}`;
  return null;
}

export function errorCategoria(valor) {
  const l = largo(valor);
  if (l === 0) return "Este campo es obligatorio.";
  if (l < 2 || l > 60) return "Escribe de 2 a 60 caracteres.";
  if (!cumple(valor, PATRONES.categoria)) return `Solo se permite: ${AYUDA.categoria}`;
  return null;
}

export function errorMesesGarantia(valor) {
  const n = Number(valor);
  if (!Number.isInteger(n) || n < 0 || n > 120) return "De 0 a 120 meses.";
  return null;
}

export function errorNumeroSerie(valor) {
  const v = String(valor ?? "").trim();
  if (v === "") return null; // opcional
  if (v.length < 3 || v.length > 60) return "De 3 a 60 caracteres.";
  if (!cumple(v, PATRONES.numeroSerie)) return `Solo se permite: ${AYUDA.numeroSerie}`;
  return null;
}

export function errorNumeroFactura(valor) {
  const v = String(valor ?? "").trim();
  if (v === "") return null; // opcional
  if (v.length > 40) return "Máximo 40 caracteres.";
  if (!cumple(v, PATRONES.numeroFactura)) return `Solo se permite: ${AYUDA.numeroFactura}`;
  return null;
}

export function errorAccesorios(valor) {
  const v = String(valor ?? "").trim();
  if (v.length > 300) return "Máximo 300 caracteres.";
  return null;
}

export function errorFallaReportada(valor) {
  const l = largo(valor);
  if (l < 5 || l > 2000) return "Describe la falla con 5 a 2000 caracteres.";
  return null;
}

export function errorFechaCompra(valor, hoyIso) {
  if (!valor || valor < "2000-01-01") return "Ingresa una fecha de compra válida (a partir del año 2000).";
  if (hoyIso && valor > hoyIso) return "La fecha de compra no puede ser futura.";
  return null;
}

export function errorMesesOverride(valor) {
  const n = Number(valor);
  if (!valor || !Number.isInteger(n) || n < 1 || n > 120) {
    return "Una garantía extendida necesita su duración, de 1 a 120 meses.";
  }
  return null;
}

export function errorSlaDias(valor) {
  const n = Number(valor);
  if (!Number.isInteger(n) || n < 1 || n > 90) return "El plazo de entrega debe estar entre 1 y 90 días.";
  return null;
}

/** ¿Un objeto de errores (mapa campo -> mensaje|null) está limpio? */
export function sinErrores(mapaErrores) {
  return Object.values(mapaErrores).every((m) => !m);
}
