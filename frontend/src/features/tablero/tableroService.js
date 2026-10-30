// Servicio del Tablero (Tarea 20 del plan): única puerta a `v_tablero`.
import { supabase } from "../../lib/supabaseClient.js";

const COLUMNAS =
  "orden_id, numero_orden, estado, estado_nombre, cobertura, serial, producto, cliente, documento, numero_soporte, fecha_ingreso, vence_el, dias_restantes, nivel_vigencia, dias_en_taller, nivel_sla, urgencia_rank, abierto";

function mapearError(err) {
  const codigo = err?.code;
  if (codigo === "42501") return { ok: false, codigo: "SIN_PERMISO", mensaje: err.message ?? "" };
  if (codigo === "401" || err?.status === 401) {
    return { ok: false, codigo: "SESION_VENCIDA", mensaje: "Tu sesión venció: vuelve a entrar para continuar" };
  }
  return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
}

/**
 * Filas del Tablero: abiertas primero (urgencia combinada, luego ingreso),
 * después los cerrados. La búsqueda multicriterio cubre serial, titular,
 * documento, número de soporte (factura) y número de orden — con UNA
 * caja de texto, porque quien atienda el mostrador tiene una sola cosa en
 * la mano (spec §7.3).
 */
export async function listarTablero({ busqueda, estado, urgencia } = {}) {
  try {
    let q = supabase.from("v_tablero").select(COLUMNAS)
      .order("urgencia_rank", { ascending: false })
      .order("fecha_ingreso", { ascending: true }).limit(200);

    if (estado) q = q.eq("estado", estado);
    if (urgencia) q = q.eq("nivel_vigencia", urgencia);

    const b = String(busqueda ?? "").trim();
    if (b) {
      const sinComo = b.replace(/[*%]/g, "");
      q = q.or(
        [
          "numero_orden.ilike.*" + sinComo + "*",
          "serial.ilike.*" + sinComo + "*",
          "cliente.ilike.*" + sinComo + "*",
          "documento.ilike.*" + sinComo + "*",
          "numero_soporte.ilike.*" + sinComo + "*",
        ].join(","),
      );
    }

    const { data, error } = await q;
    if (error) return mapearError(error);
    return { ok: true, filas: data ?? [] };
  } catch (err) {
    if (err instanceof TypeError || String(err?.name ?? "").startsWith("Fetch")) {
      return { ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión" };
    }
    return { ok: false, codigo: "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
  }
}