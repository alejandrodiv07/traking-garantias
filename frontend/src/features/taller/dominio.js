/**
 * Lo único de este módulo que NO viene de la base.
 *
 * Hasta la conexión real, este fichero era el catálogo completo de estados y
 * coberturas (nombres incluidos). Ahora que `useEstados()` (`datos/hooks.js`)
 * lee `estados_garantia` de verdad, declarar los nombres aquí otra vez sería
 * tener dos fuentes de verdad para el mismo dato: si alguien agrega un estado
 * en SQL (CU-03), esta pantalla debe mostrarlo sin que nadie toque React, y
 * eso solo es cierto si React deja de guardar la lista.
 *
 * Lo que SÍ sobrevive es el color: el color de un estado es una decisión de
 * interfaz, no un dato de negocio, y no está — ni debe estar — en la base.
 */

/* Familias visuales. Cuatro, no diez: el operador necesita distinguir
   "en curso" de "terminado" de un vistazo, no memorizar diez colores. */
const NEUTRO = "neutro";
const PROGRESO = "progreso";
const RESUELTO = "resuelto";
const ADVERSO = "adverso";

/**
 * Mapa código -> tono. Un estado que no está aquí (uno agregado en SQL sin
 * que nadie haya vuelto a este fichero) se pinta neutro: sigue siendo
 * visible y no rompe nada, solo no tiene todavía un color propio.
 */
const TONOS = Object.freeze({
  RECIBIDO: NEUTRO,
  EN_DIAGNOSTICO: PROGRESO,
  PRESUPUESTADO: PROGRESO,
  EN_ESPERA_REPUESTO: PROGRESO,
  EN_REPARACION: PROGRESO,
  REPARADO: RESUELTO,
  IRREPARABLE: ADVERSO,
  RECHAZADO_POR_CLIENTE: ADVERSO,
  ENTREGADO: RESUELTO,
  ANULADO: NEUTRO,
});

export function tonoDeEstado(codigo) {
  return TONOS[codigo] ?? NEUTRO;
}

/** ENUM `public.cobertura_garantia`. Cuatro valores fijos, no un catálogo
    consultable: cambiar esta lista es una migración, no un INSERT. */
export const COBERTURAS = Object.freeze({
  POR_DETERMINAR: { nombre: "Por determinar", tono: NEUTRO },
  EN_GARANTIA: { nombre: "En garantía", tono: RESUELTO },
  FUERA_DE_GARANTIA: { nombre: "Fuera de garantía", tono: NEUTRO },
  ANULADA_POR_USO: { nombre: "Anulada por uso", tono: ADVERSO },
});

export function cobertura(codigo) {
  return COBERTURAS[codigo] ?? { nombre: codigo, tono: NEUTRO };
}

/** Mismos dos códigos que `kpis_tablero()` excluye de "abiertas". */
export const ESTADOS_TERMINALES = Object.freeze(["ENTREGADO", "ANULADO"]);

export function estaAbierta(codigoEstado) {
  return !ESTADOS_TERMINALES.includes(codigoEstado);
}

/** Formato de fecha corto para la columna "Ingresó". */
export function fechaCorta(iso) {
  return new Date(iso).toLocaleDateString("es-VE", { day: "numeric", month: "short" });
}

/**
 * La fecha del calendario del usuario en formato `YYYY-MM-DD`.
 *
 * NO se usa `toISOString().slice(0,10)`, que da la fecha en UTC. El taller
 * está en America/Caracas (UTC-4): a partir de las 20:00 hora local, UTC ya
 * pasó de día. Con la versión UTC, el operador del turno de noche veía
 * "Venció hace 1 d" en una garantía que vence mañana, y la ventana de
 * `consultarPorVencer` empezaba en la fecha equivocada -- una garantía que
 * vence hoy desaparecía del panel a las 8 de la noche.
 */
export function fechaLocalISO(fecha = new Date()) {
  const d = fecha instanceof Date ? fecha : new Date(fecha);
  const mes = String(d.getMonth() + 1).padStart(2, "0");
  const dia = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${mes}-${dia}`;
}

/** Días que faltan (o sobran) hasta una fecha, respecto de `hoy`. Ambos
    extremos se comparan como fechas de calendario locales, no como
    instantes: "faltan 3 días" no puede cambiar a las 8 de la noche. */
export function diasHasta(isoFecha, hoy = new Date()) {
  const MS_DIA = 86_400_000;
  const a = Date.parse(String(isoFecha).slice(0, 10) + "T00:00:00");
  const b = Date.parse(fechaLocalISO(hoy) + "T00:00:00");
  return Math.round((a - b) / MS_DIA);
}
