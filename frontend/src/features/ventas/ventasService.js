// Servicio de Ventas: importa las filas ya validadas del CSV.
import { rpc } from "../registro/registroService.js";

/** Límite de filas por llamada de `importar_ventas`. */
export const TAMANO_BLOQUE = 5000;

/**
 * Envía las filas en bloques y suma los resúmenes. `errores[].fila` queda
 * numerada sobre el total enviado (1 = primera fila de `filas`). Si un bloque
 * falla, devuelve el error y cuántas filas quedaron guardadas antes.
 */
export async function importarVentas(archivo, filas) {
  const total = { nuevas: 0, actualizadas: 0, con_error: 0, confirmadas: 0, errores: [] };
  for (let desde = 0; desde < filas.length; desde += TAMANO_BLOQUE) {
    const r = await rpc("importar_ventas", { p_archivo: archivo, p_filas: filas.slice(desde, desde + TAMANO_BLOQUE) });
    if (!r.ok) return { ...r, guardadas: total.nuevas + total.actualizadas };
    const b = r.datos?.[0] ?? {};
    for (const k of ["nuevas", "actualizadas", "con_error", "confirmadas"]) total[k] += b[k] ?? 0;
    total.errores.push(...(b.errores ?? []).map((e) => ({ ...e, fila: e.fila + desde })));
  }
  return { ok: true, datos: total };
}
