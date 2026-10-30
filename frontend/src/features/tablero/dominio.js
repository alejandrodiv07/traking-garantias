/**
 * Catálogo del dominio — ESPEJO de la migración `20260906000002_garantias.sql`.
 *
 * Los códigos y sus nombres son los que ya viven en `public.estados_garantia`
 * y en el ENUM `public.cobertura_garantia`. Se replican aquí, y no se inventan
 * etiquetas nuevas, porque el día que la pantalla consulte de verdad recibirá
 * exactamente estas cadenas: si la interfaz hubiera usado un vocabulario
 * propio ("Vigente", "OS-2026-0142") habría que traducir en cada consulta y
 * cada traducción es un sitio donde se pierde un estado en silencio.
 *
 * Cuando este módulo deje de ser el catálogo y pase a leerse de la base
 * (`select * from estados_garantia order by orden`), lo único que sobrevive de
 * aquí es el mapa de CLASES CSS: el color no está en la base ni debe estarlo.
 */

/* Familias visuales. Cuatro, no diez: el operador necesita distinguir
   "en curso" de "terminado" de un vistazo, no memorizar diez colores. */
const NEUTRO = "neutro";
const PROGRESO = "progreso";
const RESUELTO = "resuelto";
const ADVERSO = "adverso";

/** Los 11 estados de `estados_garantia`, en su columna `orden`. */
export const ESTADOS = Object.freeze([
  { codigo: "RECIBIDO", nombre: "Recibido", tono: NEUTRO, final: false },
  { codigo: "EN_DIAGNOSTICO", nombre: "En diagnóstico", tono: PROGRESO, final: false },
  { codigo: "PRESUPUESTADO", nombre: "Presupuestado", tono: PROGRESO, final: false },
  { codigo: "EN_ESPERA_REPUESTO", nombre: "En espera de repuesto", tono: PROGRESO, final: false },
  { codigo: "EN_REPARACION", nombre: "En reparación", tono: PROGRESO, final: false },
  { codigo: "REPARADO", nombre: "Reparado", tono: RESUELTO, final: false },
  { codigo: "IRREPARABLE", nombre: "Irreparable", tono: ADVERSO, final: false },
  { codigo: "RECHAZADO_POR_CLIENTE", nombre: "Rechazado por cliente", tono: ADVERSO, final: false },
  // Decisión del TALLER (orden 85, migración 0016): no es terminal — su
  // única salida es ENTREGADO —, así que sigue contando como abierta.
  { codigo: "RECHAZADO", nombre: "Rechazado", tono: ADVERSO, final: false },
  { codigo: "ENTREGADO", nombre: "Entregado", tono: RESUELTO, final: true },
  { codigo: "ANULADO", nombre: "Anulado", tono: NEUTRO, final: true },
]);

const POR_CODIGO = Object.fromEntries(ESTADOS.map((e) => [e.codigo, e]));

/** Estado desconocido = se pinta neutro con su propio código, no se rompe. */
export function estado(codigo) {
  return POR_CODIGO[codigo] ?? { codigo, nombre: codigo, tono: NEUTRO, final: false };
}

/** ENUM `public.cobertura_garantia`. */
export const COBERTURAS = Object.freeze({
  POR_DETERMINAR: { nombre: "Por determinar", tono: NEUTRO },
  EN_GARANTIA: { nombre: "En garantía", tono: RESUELTO },
  FUERA_DE_GARANTIA: { nombre: "Fuera de garantía", tono: NEUTRO },
  ANULADA_POR_USO: { nombre: "Anulada por uso", tono: ADVERSO },
});

export function cobertura(codigo) {
  return COBERTURAS[codigo] ?? { nombre: codigo, tono: NEUTRO };
}

/**
 * Órdenes abiertas = las que no están en un estado terminal.
 * Misma definición que el índice parcial `idx_gar_abiertas_por_estado`.
 */
export const ESTADOS_TERMINALES = Object.freeze(["ENTREGADO", "ANULADO"]);

export function estaAbierta(codigoEstado) {
  return !ESTADOS_TERMINALES.includes(codigoEstado);
}

/**
 * Espejo de `public.transiciones_estado` (migraciones 20260906000002 y
 * 20261030000016): la matriz EXACTA que impone el trigger `registrar_garantia`
 * al UPDATE. La UI la usa para anticipar qué avances tiene sentido ofrecerle
 * a cada rol — "la interfaz ANTICIPA, la base DECIDE": si un estado del
 * espejo y la base llegaran a diferir, la llamada RPC de todas formas muere
 * con el error del trigger y la pantalla lo muestra.
 */
export const TRANSICIONES = Object.freeze(
  [
    { desde: "RECIBIDO", hasta: "EN_DIAGNOSTICO", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO"] },
    { desde: "RECIBIDO", hasta: "ANULADO", roles: ["ADMIN", "JEFE_SERVICIO"] },
    { desde: "RECIBIDO", hasta: "RECHAZADO", roles: ["ADMIN", "JEFE_SERVICIO"] },

    { desde: "EN_DIAGNOSTICO", hasta: "PRESUPUESTADO", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO"] },
    { desde: "EN_DIAGNOSTICO", hasta: "EN_REPARACION", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO"] },
    { desde: "EN_DIAGNOSTICO", hasta: "IRREPARABLE", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO"] },
    { desde: "EN_DIAGNOSTICO", hasta: "ANULADO", roles: ["ADMIN", "JEFE_SERVICIO"] },
    { desde: "EN_DIAGNOSTICO", hasta: "RECHAZADO", roles: ["ADMIN", "JEFE_SERVICIO"] },

    { desde: "PRESUPUESTADO", hasta: "EN_ESPERA_REPUESTO", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO"] },
    { desde: "PRESUPUESTADO", hasta: "EN_REPARACION", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO", "RECEPCION"] },
    { desde: "PRESUPUESTADO", hasta: "RECHAZADO_POR_CLIENTE", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO", "RECEPCION"] },
    { desde: "PRESUPUESTADO", hasta: "IRREPARABLE", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO"] },
    { desde: "PRESUPUESTADO", hasta: "RECHAZADO", roles: ["ADMIN", "JEFE_SERVICIO"] },

    { desde: "EN_ESPERA_REPUESTO", hasta: "EN_REPARACION", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO", "RECEPCION"] },
    { desde: "EN_ESPERA_REPUESTO", hasta: "IRREPARABLE", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO"] },
    { desde: "EN_ESPERA_REPUESTO", hasta: "RECHAZADO_POR_CLIENTE", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO", "RECEPCION"] },

    { desde: "EN_REPARACION", hasta: "REPARADO", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO"] },
    { desde: "EN_REPARACION", hasta: "IRREPARABLE", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO"] },
    { desde: "EN_REPARACION", hasta: "EN_ESPERA_REPUESTO", roles: ["ADMIN", "JEFE_SERVICIO", "TECNICO"] },

    { desde: "REPARADO", hasta: "ENTREGADO", roles: ["ADMIN", "JEFE_SERVICIO", "RECEPCION"] },
    { desde: "IRREPARABLE", hasta: "ENTREGADO", roles: ["ADMIN", "JEFE_SERVICIO", "RECEPCION"] },
    { desde: "RECHAZADO_POR_CLIENTE", hasta: "ENTREGADO", roles: ["ADMIN", "JEFE_SERVICIO", "RECEPCION"] },
    { desde: "RECHAZADO", hasta: "ENTREGADO", roles: ["ADMIN", "JEFE_SERVICIO", "RECEPCION"] },
  ].map((t) => ({ ...t, roles: Object.freeze(t.roles) })),
);

/** Los avances posibles desde `desde` para `rol`, en el orden de la base. */
export function transicionesDesde(desde, rol) {
  return TRANSICIONES.filter((t) => t.desde === desde && t.roles.includes(rol)).map((t) => estado(t.hasta));
}

/**
 * Chips de filtro del tablero. Deliberadamente NO son los diez estados: una
 * fila de diez chips deja de ser un filtro y pasa a ser una segunda tabla.
 * Son los cuatro tramos donde de verdad se atasca el trabajo, más "Todas".
 */
export const FILTROS = Object.freeze([
  { clave: "TODAS", etiqueta: "Todas", estados: null },
  { clave: "RECIBIDO", etiqueta: "Recibido", estados: ["RECIBIDO"] },
  { clave: "EN_DIAGNOSTICO", etiqueta: "En diagnóstico", estados: ["EN_DIAGNOSTICO"] },
  { clave: "EN_REPARACION", etiqueta: "En reparación", estados: ["EN_REPARACION", "EN_ESPERA_REPUESTO"] },
  { clave: "REPARADO", etiqueta: "Reparado", estados: ["REPARADO"] },
]);

/** Formato de fecha corto para la columna "Ingresó". */
export function fechaCorta(iso) {
  return new Date(iso).toLocaleDateString("es-VE", { day: "numeric", month: "short" });
}

/** Días que faltan (o sobran) hasta una fecha, respecto de `hoy`. */
export function diasHasta(isoFecha, hoy = new Date()) {
  const MS_DIA = 86_400_000;
  const a = Date.parse(isoFecha.slice(0, 10) + "T00:00:00");
  const b = Date.parse(hoy.toISOString().slice(0, 10) + "T00:00:00");
  return Math.round((a - b) / MS_DIA);
}
