// Borrador local del asistente (Tarea 16 del plan; spec §7.2).
// Las laptops del taller son COMPARTIDAS: la clave lleva el id del
// usuario, caduca a las 24 horas y jamás incluye archivos.
// localStorage del navegador: muere con el perfil/caché, no va a la base.

const CLAVE = (userId) => `pt.borrador.${userId}`;
const VIDA_MS = 24 * 60 * 60 * 1000;   // 24 horas

/** ¿Vive un File/Blob DENTRO de este valor (listas y objetos incluidos)? */
function contieneArchivo(v, vistos = new Set()) {
  if (!v || typeof v !== "object") return false;
  if (v instanceof File || v instanceof Blob) return true;
  if (vistos.has(v)) return false;
  vistos.add(v);
  if (Array.isArray(v)) {
    return v.some((i) => contieneArchivo(i, vistos));
  }
  return Object.values(v).some((i) => contieneArchivo(i, vistos));
}

/**
 * El borrador es datos del cliente: jamás un File. Y ojo con la profundidad:
 * los adjuntos viven en `archivosAdjuntos` (lista de {archivo: File, ...}) —
 * si se serializaran quedarían stubs ({archivo: {}}) que al restaurar
 * entraban como pendientes eternos que `subirAdjunto` rechaza por MIME
 * vacío. Todo valor que contenga un archivo a cualquier profundidad se VA.
 */
function limpiarArchivos(estado) {
  if (!estado || typeof estado !== "object") return {};
  const limpio = {};
  for (const [k, v] of Object.entries(estado)) {
    if (v instanceof File || v instanceof Blob) continue;
    if (contieneArchivo(v)) continue;
    limpio[k] = v;
  }
  return limpio;
}

export function guardarBorrador(userId, estado) {
  try {
    localStorage.setItem(
      CLAVE(userId),
      JSON.stringify({
        guardado_en: new Date().toISOString(),
        estado: limpiarArchivos(estado),
      }),
    );
  } catch {
    /* storage lleno o bloqueado: el borrador es una comodidad, no una garantía */
  }
}

export function leerBorrador(userId) {
  try {
    const texto = localStorage.getItem(CLAVE(userId));
    if (!texto) return null;
    const { guardado_en, estado } = JSON.parse(texto);
    if (!guardado_en || new Date(guardado_en).getTime() + VIDA_MS <= new Date().getTime()) {
      localStorage.removeItem(CLAVE(userId));   // caducado: se borra
      return null;
    }
    return estado ?? null;
  } catch {
    try {
      localStorage.removeItem(CLAVE(userId));
    } catch { /* nada */ }
    return null;
  }
}

export function limpiarBorrador(userId) {
  try {
    localStorage.removeItem(CLAVE(userId));
  } catch { /* nada */ }
}

/** Al cerrar sesión en un PC compartido, se borran TODOS los borradores. */
export function limpiarBorradores() {
  try {
    const aBorrar = [];
    for (let i = 0; i < localStorage.length; i += 1) {
      const clave = localStorage.key(i);
      if (clave?.startsWith("pt.borrador.")) aBorrar.push(clave);
    }
    for (const clave of aBorrar) localStorage.removeItem(clave);
  } catch { /* nada */ }
}