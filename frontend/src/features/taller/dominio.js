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

/** Días que faltan (o sobran) hasta una fecha, respecto de `hoy`. */
export function diasHasta(isoFecha, hoy = new Date()) {
  const MS_DIA = 86_400_000;
  const a = Date.parse(isoFecha.slice(0, 10) + "T00:00:00");
  const b = Date.parse(hoy.toISOString().slice(0, 10) + "T00:00:00");
  return Math.round((a - b) / MS_DIA);
}
